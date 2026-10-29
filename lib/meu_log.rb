# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"   # o `iso8601` da janela de medicao


# Cliente do meulog para Ruby e Rails.
#
# Fino de proposito. O trabalho esta na API; isto so embala a chamada, e e por
# isso que cabe num arquivo. Nao depende de Rails nem de ActiveSupport: da para
# usar num script, num Sidekiq worker ou num rake.
#
#   MeuLog.configure do |c|
#     c.url      = "https://meulog.monde.com.br"
#     c.token    = ENV["MEULOG_TOKEN"]
#     c.ambiente = Rails.env.to_s
#     c.versao   = ENV["APP_VERSION"]
#   end
#
#   # captura automatica no Rails (config/application.rb):
#   config.middleware.use MeuLog::Middleware
#
#   # captura manual, onde voce ja trata a excecao:
#   rescue => e
#     MeuLog.notify(e, pedido_id: pedido.id)
#     raise
#   end
#
#   # sinal de vida de um job que roda sozinho:
#   MeuLog.heartbeat("faturamento-noturno", interval_minutes: 1440)
#
#   # o que a pessoa fez, para a linha do tempo ao lado do erro:
#   MeuLog.track("emitiu nota", user: usuario.login, customer: empresa.cnpj)
#   c.track_requests = true   # e uma por requisicao, pelo middleware
module MeuLog
  # Frames demais nao ajudam a achar o bug e engordam cada evento.
  LIMITE_DE_FRAMES = 50
  # Um cliente lento nao pode segurar a resposta do usuario.
  ESPERA = 5

  # As fronteiras de medicao sao do servidor, e esta copia existe para o cliente
  # poder contar antes de mandar. O numero do esquema viaja no corpo e e o que
  # impede uma copia velha de somar em silencio com as contagens de hoje: o
  # servidor recusa alto em vez de reinterpretar.
  #
  # No modulo, e nao dentro de `class << self`: o esquema e contrato publico, e um
  # teste do lado do servidor le daqui para provar que os dois concordam.
  ESQUEMA_DE_MEDICAO = 1
  FRONTEIRAS = [ 10, 25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12_800,
                 25_600, 51_200, 102_400, 204_800 ].freeze
  BALDES = FRONTEIRAS.size + 1
  # A grade do servidor. Acumular por minuto e mandar de tempos em tempos e o que
  # faz um processo falante e um quieto custarem a mesma coisa la dentro.
  JANELA = 60
  # Um lote de uso e o teto da porta; o acumulado tem teto para um laco nao comer memoria.
  LOTE_DE_USO = 500
  LIMITE_DE_USO = 10_000

  class << self
    attr_accessor :url, :token, :ambiente, :versao, :servidor, :logger, :track_requests
    attr_writer :synchronous

    def configure
      yield self
      self
    end

    # Envia em outra thread: reportar erro nao pode custar latencia a quem esta
    # esperando a pagina. Em script curto ligue `synchronous = true`, senao o
    # processo termina antes da thread.
    def synchronous? = @synchronous ? true : false

    def configured? = !to_s_vazio?(url) && !to_s_vazio?(token)

    def notify(excecao, contexto = {})
      return false unless configured?

      entregar("/api/v1/events", event: corpo_do_evento(excecao, contexto))
    end

    # ===== PATCH LOCAL (meu-personal) — ver minhasuite/meu-log#11 ======================
    # `usuario` e `cliente` sao COLUNAS no meulog (contrato: `user` e `customer` no
    # topo do evento), e e delas que vivem as telas de Clientes e de usuario. O SDK
    # so sabe mandar contexto livre, que vira atributo pesquisavel e nao preenche
    # coluna nenhuma — entao o erro do servidor chegava sem plano e sem dono.
    #
    # Isto e um patch no arquivo VENDORIZADO: ao trazer uma versao nova do SDK,
    # reaplique ou apague junto com a chamada em MeuLogErrorSubscriber.
    def notify_como(excecao, usuario: nil, cliente: nil, **contexto)
      return false unless configured?

      corpo = corpo_do_evento(excecao, contexto)
      corpo[:user] = usuario.to_s if usuario
      corpo[:customer] = cliente.to_s if cliente
      entregar("/api/v1/events", event: corpo)
    end
    # ===== fim do patch local ====================================================

    # Diz ao meulog que este job rodou. A primeira chamada cadastra.
    # `intervalo_minutos:` continua valendo junto com `interval_minutes:`: está
    # escrito em job que roda em produção, e keyword que some levanta na hora.
    def heartbeat(nome, interval_minutes: nil, tolerance_minutes: nil,
                  intervalo_minutos: nil, tolerancia_minutos: nil)
      return false unless configured?

      intervalo = interval_minutes || intervalo_minutos
      raise ArgumentError, "missing keyword: :interval_minutes" if intervalo.nil?

      entregar("/api/v1/heartbeats", name: nome, interval_minutes: intervalo,
                                     tolerance_minutes: tolerance_minutes || tolerancia_minutos)
    end

    # -- medicao de tempo -------------------------------------------------------

    # Cronometra o bloco e devolve o que ele devolveu.
    #
    #   MeuLog.measure("faturamento") { Fatura.gerar(mes) }
    #
    # Nunca levanta por conta propria, e nunca engole a excecao do bloco: se o
    # trabalho medido falhou, quem chamou precisa saber, e a medicao entra contada
    # como erro. E o espelho da regra do reporte — measure nao pode custar a operacao
    # medida.
    def measure(nome)
      inicio = agora_em_ms
      falhou = false
      yield
    rescue Exception # rubocop:disable Lint/RescueException
      falhou = true
      raise
    ensure
      record_time(nome, (agora_em_ms - inicio).round, falhou: falhou)
    end

    # Para quem ja tem o numero na mao.
    def record_time(nome, ms, falhou: false)
      return false unless configured?

      acumular(nome.to_s, ms.to_i, falhou)
      iniciar_descarga
      true
    rescue StandardError => e
      logger&.warn("[meulog] nao consegui medir: #{e.class}: #{e.message}")
      false
    end

    # Manda agora o que estiver acumulado. Chamado sozinho no fim do processo.
    def flush
      janelas, usos = travar do
        pendentes = [ @janelas, @usos ]
        @janelas = {}
        @usos = []
        pendentes
      end
      return false if janelas.empty? && usos.empty?

      unless janelas.empty?
        entregar("/api/v1/measurements",
                 schema: ESQUEMA_DE_MEDICAO,
                 windows: janelas.map { |chave, dados| janela_de(chave, dados) })
      end
      usos.each_slice(LOTE_DE_USO) { |lote| entregar("/api/v1/usage", events: lote) }
      true
    end

    # -- uso ----------------------------------------------------------------------

    # O que a pessoa fez, para ficar ao lado do erro na linha do tempo.
    #
    #   MeuLog.track("emitiu nota", user: usuario.login, customer: empresa.cnpj, nota: nota.id)
    #
    # Acumula e sai junto com a medicao, a cada minuto: um clique nao pode custar uma
    # requisicao. Como o reporte, nunca levanta.
    def track(nome, category: "custom", user: nil, customer: nil, session: nil, **contexto)
      return false unless configured?

      evento = { name: nome.to_s, category: category, occurred_at: Time.now.utc.iso8601,
                 user: user, customer: customer, session: session, platform: "ruby",
                 version: versao, machine: servidor || (@servidor_padrao ||= padrao_do_servidor),
                 context: contexto }.reject { |_, valor| to_s_vazio?(valor) }
      travar do
        @usos.shift if @usos.size >= LIMITE_DE_USO
        @usos << evento
      end
      iniciar_descarga
      true
    rescue StandardError => e
      logger&.warn("[meulog] nao consegui anotar o uso: #{e.class}: #{e.message}")
      false
    end

    # O nome antigo, em português, continua respondendo: há aplicação em produção
    # com `MeuLog.configure` e `MeuLog.heartbeat` no código, e um método que some não dá
    # erro de carga — dá um job que parou de bater sem ninguém notar.
    alias configurar configure
    alias sincrono? synchronous?
    alias configurado? configured?
    alias bater heartbeat
    alias medir measure
    alias registrar_tempo record_time
    alias descarregar flush

    def sincrono=(valor)
      self.synchronous = valor
    end

    private

    def agora_em_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000

    def travar(&bloco)
      @trava ||= Mutex.new
      @janelas ||= {}
      @usos ||= []
      @trava.synchronize(&bloco)
    end

    def acumular(nome, ms, falhou)
      janela = Time.now.to_i / JANELA * JANELA
      travar do
        dados = (@janelas[[ nome, janela ]] ||= { baldes: Array.new(BALDES, 0), soma: 0,
                                                  maximo: nil, minimo: nil, erros: 0 })
        dados[:baldes][balde_de(ms)] += 1
        dados[:soma] += ms
        dados[:maximo] = [ dados[:maximo], ms ].compact.max
        dados[:minimo] = [ dados[:minimo], ms ].compact.min
        dados[:erros] += 1 if falhou
      end
    end

    def balde_de(ms) = FRONTEIRAS.index { |limite| ms <= limite } || BALDES - 1

    def janela_de(chave, dados)
      nome, segundos = chave
      { name: nome, window_at: Time.at(segundos).utc.iso8601,
        buckets: dados[:baldes], sum_ms: dados[:soma],
        max_ms: dados[:maximo], min_ms: dados[:minimo],
        errors: dados[:erros], environment: ambiente, version: versao }
    end

    # A thread nao nasce no `require`.
    #
    # Uma rake task que carrega este arquivo nao deveria ganhar uma thread de fundo,
    # e — o que importa mais — um processo que faz `fork` depois de subir (Puma,
    # Passenger) perderia a thread no filho e pararia de mandar em silencio. Nascer
    # na primeira medicao resolve os dois de graca.
    def iniciar_descarga
      return if @descarga&.alive?

      @descarga = Thread.new do
        loop do
          sleep(JANELA)
          begin
            flush
          rescue StandardError
            nil
          end
        end
      end
      # Script curto mediria e sairia sem mandar nada. E a mesma pegadinha que o
      # `synchronous?` deste arquivo ja documenta para o reporte de erro.
      at_exit { flush rescue nil } unless @saida_registrada
      @saida_registrada = true
    end

    def corpo_do_evento(excecao, contexto)
      {
        platform: "ruby",
        class: excecao.class.name,
        message: excecao.message.to_s,
        version: versao,
        environment: ambiente,
        server: servidor || padrao_do_servidor,
        context: contexto,
        frames: frames_de(excecao)
      }.reject { |_, valor| to_s_vazio?(valor) }
    end

    # `backtrace_locations` ja vem separado; o `backtrace` cru precisa de regex.
    def frames_de(excecao)
      locais = excecao.backtrace_locations
      return de_locations(locais) if locais

      de_texto(excecao.backtrace || [])
    end

    def de_locations(locais)
      locais.first(LIMITE_DE_FRAMES).map do |local|
        { file: local.path.to_s, line: local.lineno, method: local.label.to_s }
      end
    end

    def de_texto(linhas)
      linhas.first(LIMITE_DE_FRAMES).filter_map do |linha|
        partes = linha.match(/\A(.+?):(\d+)(?::in [`'](.+)['`])?/)
        next if partes.nil?

        { file: partes[1], line: partes[2].to_i, method: partes[3].to_s }
      end
    end

    def padrao_do_servidor
      require "socket"
      Socket.gethostname
    rescue StandardError
      nil
    end

    def entregar(caminho, corpo)
      return postar(caminho, corpo) if synchronous?

      Thread.new { postar(caminho, corpo) }
      true
    end

    def postar(caminho, corpo)
      alvo = URI.join(url.to_s.sub(%r{/+\z}, "") + "/", caminho.sub(%r{\A/+}, ""))
      http = Net::HTTP.new(alvo.host, alvo.port)
      http.use_ssl = alvo.scheme == "https"
      http.open_timeout = ESPERA
      http.read_timeout = ESPERA

      pedido = Net::HTTP::Post.new(alvo)
      pedido["Authorization"] = "Bearer #{token}"
      pedido["Content-Type"] = "application/json"
      pedido.body = JSON.generate(corpo)

      resposta = http.request(pedido)
      resposta.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      # Reportar erro nunca pode virar erro. O meulog fora do ar nao derruba quem
      # o chamou; no maximo escreve uma linha no log de quem chamou.
      logger&.warn("[meulog] nao consegui reportar: #{e.class}: #{e.message}")
      false
    end

    def to_s_vazio?(valor) = valor.nil? || valor.to_s.strip.empty?
  end

  # Captura o que subir ate o topo da pilha Rack e deixa passar.
  #
  #   config.middleware.use MeuLog::Middleware
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      inicio = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resposta = @app.call(env)
      anotar(env, resposta.first, inicio)
      resposta
    rescue Exception => e # rubocop:disable Lint/RescueException
      anotar(env, 500, inicio)
      MeuLog.notify(e, contexto_de(env))
      raise
    end

    private

    # A requisicao vira um passo na linha do tempo, quando `track_requests` esta
    # ligado. Quem e a pessoa a aplicacao diz em `env["meulog.user"]` e
    # `env["meulog.customer"]`: o middleware nao sabe o que e login em cada app.
    def anotar(env, status, inicio)
      return unless MeuLog.track_requests

      MeuLog.track("#{env['REQUEST_METHOD']} #{env['PATH_INFO']}",
                 category: "request", user: env["meulog.user"], customer: env["meulog.customer"],
                 status: status.to_i,
                 duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - inicio) * 1000).round)
    end

    # O que ajuda a reproduzir, sem cookie nem cabecalho de autorizacao: eles
    # levariam sessao e token para dentro do meulog.
    def contexto_de(env)
      {
        url: "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}#{env['REQUEST_URI'] || env['PATH_INFO']}",
        metodo_http: env["REQUEST_METHOD"],
        ip: env["action_dispatch.remote_ip"]&.to_s || env["REMOTE_ADDR"],
        navegador: env["HTTP_USER_AGENT"],
        requisicao_id: env["action_dispatch.request_id"]
      }.reject { |_, valor| valor.nil? || valor.to_s.empty? }
    end
  end
end
