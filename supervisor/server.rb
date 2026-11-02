# Supervisor dos aplicativos (F8g): o ÚNICO serviço que monta o socket do
# Docker. Ruby na própria imagem do app (zero imagem nova para enviar ao Dell e
# o catálogo vem versionado junto), só stdlib + puma/rack já instalados.
#
# API HTTP na rede interna do compose (porta 8099, sem publicar no host),
# com `Authorization: Bearer $SUPERVISOR_TOKEN`. Só opera apps do catálogo
# (lib/app_catalog.rb): imagem, portas, volumes, rede e devices vêm do
# manifesto; do pedido só as opções do schema. Só mexe em container com o
# label `minha-automacao.app`; apps "do sistema" (serviços do compose) só
# status, log e reiniciar.
require "json"
require "net/http"
require "socket"
require "rack"
require_relative "../lib/app_catalog"

module Supervisor
  Error = Class.new(StandardError)
  LOG = $stdout.tap { |io| io.sync = true }

  def self.log(msg) = LOG.puts("[supervisor] #{msg}")

  # Cliente mínimo da API do Docker pelo socket unix.
  class Docker
    class UnixHTTP < Net::HTTP
      def initialize(path, _port = nil) # Net::HTTP.new repassa (endereço, porta)
        super("localhost", 80)
        @sock_path = path
      end

      def connect
        @socket = Net::BufferedIO.new(UNIXSocket.new(@sock_path), read_timeout: @read_timeout)
        on_connect
      end
    end

    def initialize(path = "/var/run/docker.sock") = @path = path

    # → [status, corpo] (JSON quando der); erro do Docker (>= 400, fora 404/304) levanta.
    def call(method, path, body: nil, query: {}, timeout: 30)
      q = query.empty? ? "" : "?#{URI.encode_www_form(query)}"
      req = Net::HTTP.const_get(method.to_s.capitalize).new("#{path}#{q}", "Content-Type" => "application/json")
      req.body = JSON.generate(body) if body
      http = UnixHTTP.new(@path)
      http.read_timeout = timeout
      res = http.start { |h| h.request(req) }
      data = parse(res.body.to_s)
      code = res.code.to_i
      raise Error, (data.is_a?(Hash) && data["message"]) || "docker #{code}" if code >= 400 && code != 404

      [ code, data ]
    end

    def containers(labels) = call(:get, "/containers/json", query: { all: 1, filters: JSON.generate(label: labels) }).last
    def inspect(id) = call(:get, "/containers/#{id}/json").last

    def pull(ref)
      image, tag = ref.split(/:(?=[^:\/]+\z)/)
      _, body = call(:post, "/images/create", query: { fromImage: image, tag: tag }, timeout: 1800)
      events = body.is_a?(String) ? body.lines.map { |l| parse(l) } : [ body ] # progresso: um JSON por linha
      err = events.filter_map { |e| e["error"] if e.is_a?(Hash) }.first
      raise Error, err if err
    end

    def logs(id, lines)
      _, body = call(:get, "/containers/#{id}/logs", query: { stdout: 1, stderr: 1, timestamps: 1, tail: lines })
      demux(body.to_s.b).force_encoding("UTF-8").scrub
    end

    def memory_mb(id)
      s = call(:get, "/containers/#{id}/stats", query: { stream: 0, "one-shot": 1 }).last
      m = s.is_a?(Hash) ? s["memory_stats"].to_h : {}
      return nil unless m["usage"]

      ((m["usage"] - m.dig("stats", "inactive_file").to_i) / 1_048_576.0).round(1)
    end

    private

    def parse(str)
      JSON.parse(str)
    rescue JSON::ParserError
      str
    end

    # Log sem TTY vem multiplexado: quadros de 8 bytes (fluxo, 0, 0, 0, tamanho).
    def demux(raw)
      out = +""
      i = 0
      while i + 8 <= raw.bytesize && raw.getbyte(i) <= 2 && raw.byteslice(i + 1, 3) == "\0\0\0"
        len = raw.byteslice(i + 4, 4).unpack1("N")
        out << raw.byteslice(i + 8, len)
        i += 8 + len
      end
      i.zero? ? raw : out
    end
  end

  class App
    ACTIONS = %w[start stop restart].freeze
    SYSTEM_ACTIONS = %w[restart].freeze
    PATH = %r{\A/apps(?:/([a-z0-9_]+)(?:/([a-z]+))?)?\z}

    def initialize(docker:, token:, network:, project:, env: ENV)
      @docker = docker
      @token = token.to_s
      @network = network
      @project = project
      @server_env = env.to_h.slice(*AppCatalog::SERVER_ENV)
      @jobs = {}
      @lock = Mutex.new
    end

    def call(rack_env)
      req = Rack::Request.new(rack_env)
      return json(200, ok: true) if req.path_info == "/health"
      return json(401, error: "Não autorizado.") unless authorized?(req)
      return system_route(req) if req.path_info.start_with?("/system/")

      route(req)
    rescue AppCatalog::Invalid, Error => e
      json(422, error: e.message)
    rescue StandardError => e
      Supervisor.log("erro #{e.class}: #{e.message}")
      json(500, error: "Erro no supervisor.")
    end

    # Usado pela thread do watchdog: reinicia app instalado que ficou
    # "unhealthy" com política de reinício (o Docker não faz isso sozinho).
    def watchdog!
      @docker.containers([ AppCatalog::LABEL ]).each do |c|
        info = @docker.inspect(c["Id"])
        # Saúde só vale rodando: parado pelo usuário guarda o último "unhealthy".
        next unless info.dig("State", "Running") && info.dig("State", "Health", "Status") == "unhealthy" &&
                    info.dig("HostConfig", "RestartPolicy", "Name") != "no"

        Supervisor.log("watchdog: reiniciando #{info.dig('Config', 'Labels', AppCatalog::LABEL)}")
        @docker.call(:post, "/containers/#{c['Id']}/restart")
      end
    end

    # ---- Produto: atualização do servidor e acesso remoto ----------------
    UPDATER_IMAGE = "docker:27.5-cli".freeze # docker + compose; roda o bin/ma-update fora deste container
    IMAGE_REF = %r{\A#{Regexp.escape(ENV.fetch("UPDATE_IMAGE_REPO", "ghcr.io/minhasuite/minha-automacao"))}:[\w][\w.-]{0,63}\z}
    UPDATER_LABEL = "minha-automacao.updater".freeze
    REMOTE_LABEL = "minha-automacao.remote".freeze
    REMOTE_IMAGES = { "cloudflare" => "cloudflare/cloudflared:2025.10.0" }.freeze

    def system_route(req)
      body = req.post? ? (JSON.parse(req.body.read.to_s.then { |x| x.empty? ? "{}" : x }) rescue {}) : {}
      case "#{req.request_method} #{req.path_info}"
      when "POST /system/update" then update_server(body["image"].to_s)
      when "GET /system/remote" then json(200, data: remote_status)
      when "POST /system/remote" then remote_on(body["provider"].to_s, body["token"].to_s)
      when "DELETE /system/remote" then remote_off
      else json(404, error: "Não encontrado.")
      end
    end

    # Pasta do compose no servidor (label do próprio supervisor): o atualizador monta a mesma.
    def install_dir
      me = @docker.containers([ "com.docker.compose.project=#{@project}", "com.docker.compose.service=supervisor" ]).first or raise(Error, "Supervisor fora do compose.")
      @docker.inspect(me["Id"]).dig("Config", "Labels", "com.docker.compose.project.working_dir") or raise(Error, "Pasta do compose desconhecida.")
    end

    # Baixa a imagem nova e entrega o resto ao bin/ma-update num container à
    # parte: subir o compose recria este supervisor, o atualizador não pode morrer junto.
    def update_server(image)
      return json(422, error: "Imagem fora do produto.") unless image.match?(IMAGE_REF)

      running = @docker.containers([ UPDATER_LABEL ]).any? { |c| @docker.inspect(c["Id"]).dig("State", "Running") }
      return json(409, error: "Já existe uma atualização em andamento.") if running

      dir = install_dir
      Supervisor.log("atualizar para #{image}")
      @docker.pull(image)
      @docker.pull(UPDATER_IMAGE)
      script = File.read(File.expand_path("../bin/ma-update", __dir__))
      body = { "Image" => UPDATER_IMAGE, "Cmd" => [ "sh", "-c", script ], "WorkingDir" => dir,
               "Env" => [ "DIR=#{dir}", "NEW_IMAGE=#{image}" ], "Labels" => { UPDATER_LABEL => "1" },
               "HostConfig" => { "Binds" => [ "/var/run/docker.sock:/var/run/docker.sock", "#{dir}:#{dir}" ], "AutoRemove" => true } }
      _, created = @docker.call(:post, "/containers/create", body: body, query: { name: "minha-automacao-updater-#{Time.now.to_i}" })
      @docker.call(:post, "/containers/#{created['Id']}/start")
      json(202, data: { image: image })
    end

    # Túnel do acesso remoto ligado pela tela (o do compose, perfil `tunnel`, é o manual).
    def remote_status
      manual = @docker.containers([ "com.docker.compose.project=#{@project}", "com.docker.compose.service=cloudflared" ]).first
      c = @docker.containers([ REMOTE_LABEL ]).first
      info = c && @docker.inspect(c["Id"])
      { manual: !manual.nil?, provider: info&.dig("Config", "Labels", REMOTE_LABEL), state: info&.dig("State", "Status"),
        started_at: info&.dig("State", "StartedAt") }
    end

    def remote_on(provider, token)
      image = REMOTE_IMAGES[provider] or return json(422, error: "Provedor desconhecido.")
      return json(422, error: "Token inválido.") unless token.match?(/\A[A-Za-z0-9_.=+\/-]{20,4096}\z/)
      return json(409, error: "Já existe um túnel configurado no servidor (.env).") if remote_status[:manual]

      remote_off
      @docker.pull(image)
      body = { "Image" => image, "Cmd" => %w[tunnel --no-autoupdate run], "Env" => [ "TUNNEL_TOKEN=#{token}" ],
               "Labels" => { REMOTE_LABEL => provider },
               "HostConfig" => { "RestartPolicy" => { "Name" => "unless-stopped" }, "NetworkMode" => "#{@project}_default" } }
      _, created = @docker.call(:post, "/containers/create", body: body, query: { name: "minha-automacao-remote" })
      @docker.call(:post, "/containers/#{created['Id']}/start")
      Supervisor.log("acesso remoto ligado (#{provider})")
      json(200, data: remote_status)
    end

    def remote_off
      @docker.containers([ REMOTE_LABEL ]).each { |c| @docker.call(:delete, "/containers/#{c['Id']}", query: { force: 1 }) }
      json(200, data: remote_status)
    end

    private

    def authorized?(req)
      given = req.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")
      !@token.empty? && Rack::Utils.secure_compare(given, @token)
    end

    def route(req)
      m = PATH.match(req.path_info) or return json(404, error: "Não encontrado.")
      return json(200, data: AppCatalog.all.map { |a| status(a) }) if m[1].nil? && req.get?

      app = m[1] && AppCatalog.find(m[1]) or return json(404, error: "App fora do catálogo.")
      body = req.post? || req.put? ? (JSON.parse(req.body.read.to_s.then { |s| s.empty? ? "{}" : s }) rescue {}) : {}
      verb = "#{req.request_method} #{m[2]}".strip
      case verb
      when "GET" then json(200, data: status(app))
      when "GET logs" then json(200, data: { lines: logs(app, req.params["lines"]) })
      when "POST install" then install(app, body)
      when "PUT config" then configure(app, body)
      when "POST update" then upgrade(app)
      when "DELETE" then uninstall(app, req.params["keep_data"] == "1")
      else
        verb.start_with?("POST ") ? act(app, m[2]) : json(404, error: "Não encontrado.")
      end
    end

    def container(app)
      labels = app.system? ? [ "com.docker.compose.project=#{@project}", "com.docker.compose.service=#{app.system_service}" ] : [ "#{AppCatalog::LABEL}=#{app.key}" ]
      c = @docker.containers(labels).first
      c && @docker.inspect(c["Id"])
    end

    def status(app)
      c = container(app)
      job = @lock.synchronize { @jobs[app.key] }
      out = { key: app.key, system: app.system?, installed: !c.nil?, busy: job&.dig(:busy), error: job&.dig(:error) }
      return out unless c

      labels = c.dig("Config", "Labels") || {}
      policy = c.dig("HostConfig", "RestartPolicy", "Name").to_s
      running = c.dig("State", "Status") == "running"
      out.merge(state: c.dig("State", "Status"), health: (c.dig("State", "Health", "Status") if running), started_at: c.dig("State", "StartedAt"),
                version: labels["minha-automacao.version"] || app.version,
                options: (JSON.parse(labels["minha-automacao.options"]) rescue {}),
                boot: %w[always unless-stopped].include?(policy), watchdog: policy != "no" && !policy.empty?,
                memory_mb: (running ? (@docker.memory_mb(c["Id"]) rescue nil) : nil))
    end

    def logs(app, lines)
      c = container(app) or raise(Error, "App não instalado.")
      @docker.logs(c["Id"], lines.to_i.clamp(10, 1000))
    end

    def act(app, action)
      allowed = app.system? ? SYSTEM_ACTIONS : ACTIONS
      return json(422, error: "Ação não permitida.") unless allowed.include?(action)

      c = container(app) or return json(404, error: "App não instalado.")
      Supervisor.log("#{action} #{app.key}")
      @docker.call(:post, "/containers/#{c['Id']}/#{action}", query: action == "start" ? {} : { t: 10 })
      json(200, data: status(app))
    end

    def install(app, body)
      return json(422, error: "App do sistema não é instalado aqui.") if app.system?
      return json(409, error: "Já instalado.") if container(app)

      opts, errors = app.clean_options(body["options"])
      return json(422, error: "Opções inválidas.", errors: errors) unless errors.empty?

      background(app, "Instalando") { create!(app, opts, restart_policy(body)) }
    end

    def configure(app, body)
      return json(422, error: "App do sistema não é configurado aqui.") if app.system?

      c = container(app) or return json(404, error: "App não instalado.")
      st = status(app)
      policy = restart_policy({ "boot" => st[:boot], "watchdog" => st[:watchdog] }.merge(body.slice("boot", "watchdog")))
      return update_policy(app, c, policy) unless body.key?("options")

      opts, errors = app.clean_options(body["options"], current_env_options(app, c))
      return json(422, error: "Opções inválidas.", errors: errors) unless errors.empty?

      background(app, "Aplicando a configuração") { recreate!(app, c, opts, policy) }
    end

    def upgrade(app)
      return json(422, error: "App do sistema é atualizado com o servidor.") if app.system?

      c = container(app) or return json(404, error: "App não instalado.")
      opts = current_env_options(app, c)
      policy = c.dig("HostConfig", "RestartPolicy", "Name")
      background(app, "Atualizando para #{app.version}") { recreate!(app, c, opts, policy) }
    end

    def uninstall(app, keep_data)
      return json(422, error: "App do sistema não pode ser desinstalado.") if app.system?

      c = container(app) or return json(404, error: "App não instalado.")
      Supervisor.log("desinstalar #{app.key} (manter dados: #{keep_data})")
      @docker.call(:delete, "/containers/#{c['Id']}", query: { force: 1 })
      unless keep_data
        @docker.call(:get, "/volumes", query: { filters: JSON.generate(label: [ "#{AppCatalog::LABEL}=#{app.key}" ]) })
               .last.fetch("Volumes", []).each { |v| @docker.call(:delete, "/volumes/#{v['Name']}") }
      end
      @lock.synchronize { @jobs.delete(app.key) }
      json(200, data: status(app))
    end

    def update_policy(app, cont, policy)
      Supervisor.log("política #{policy} #{app.key}")
      @docker.call(:post, "/containers/#{cont['Id']}/update", body: { RestartPolicy: { Name: policy } })
      json(200, data: status(app))
    end

    def restart_policy(body)
      return "unless-stopped" if [ true, "1", "true" ].include?(body["boot"])

      [ true, "1", "true" ].include?(body["watchdog"]) ? "on-failure" : "no"
    end

    # Opções atuais (do label) com os segredos lidos do env do container.
    def current_env_options(app, cont)
      opts = JSON.parse(cont.dig("Config", "Labels", "minha-automacao.options") || "{}")
      env = (cont.dig("Config", "Env") || []).to_h { |e| e.split("=", 2) }
      app.options.each { |o| opts[o["key"]] = env[o["env"]] if o["secret"] && o["env"] }
      opts
    end

    def background(app, label)
      @lock.synchronize do
        return json(409, error: "Aguarde: #{@jobs[app.key][:busy]}.") if @jobs.dig(app.key, :busy)

        @jobs[app.key] = { busy: label }
      end
      Supervisor.log("#{label}: #{app.key}")
      Thread.new do
        yield
        @lock.synchronize { @jobs.delete(app.key) }
        Supervisor.log("ok: #{app.key}")
      rescue StandardError => e
        Supervisor.log("falhou #{app.key}: #{e.message}")
        @lock.synchronize { @jobs[app.key] = { error: e.message } }
      end
      json(202, data: { key: app.key, busy: label })
    end

    def create!(app, opts, policy)
      @docker.pull(app.image_ref)
      app.volumes.each do |v|
        @docker.call(:post, "/volumes/create", body: { Name: app.volume_name(v), Labels: { AppCatalog::LABEL => app.key } })
      end
      network = app.network == "apps" ? @network : "bridge"
      body = app.container_body(opts, network: network, restart: policy, server_env: @server_env)
      _, created = @docker.call(:post, "/containers/create", body: body, query: { name: app.container_name })
      @docker.call(:post, "/containers/#{created['Id']}/start")
    end

    def recreate!(app, cont, opts, policy)
      @docker.pull(app.image_ref)
      @docker.call(:delete, "/containers/#{cont['Id']}", query: { force: 1 })
      create!(app, opts, policy)
    end

    def json(code, body) = [ code, { "content-type" => "application/json" }, [ JSON.generate(body) ] ]
  end
end

if $PROGRAM_NAME == __FILE__
  require "puma"
  require "puma/server"
  token = ENV.fetch("SUPERVISOR_TOKEN", "")
  abort("[supervisor] SUPERVISOR_TOKEN ausente ou curto") if token.length < 32
  app = Supervisor::App.new(docker: Supervisor::Docker.new, token: token,
                            network: ENV.fetch("APPS_NETWORK", "minha-automacao-apps"),
                            project: ENV.fetch("APPS_PROJECT", "minha-automacao"))
  Thread.new do
    loop do
      sleep 30
      app.watchdog!
    rescue StandardError => e
      Supervisor.log("watchdog: #{e.message}")
    end
  end
  server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 4)
  server.add_tcp_listener("0.0.0.0", 8099)
  Supervisor.log("ouvindo em :8099")
  server.run.join
end
