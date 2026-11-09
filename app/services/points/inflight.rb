module Points
  # Comando a caminho do aparelho (retorno imediato na tela): o aparelho de verdade
  # leva segundos para responder (o comando vai pela fila), e sem isto o tile voltaria
  # ao estado antigo ao recarregar, até o aparelho avisar. Para cada ponto, olha o
  # último comando ainda sem resposta (o valor não mudou desde que ele saiu):
  #
  #   { "pending" => true, "expect" => true }   # enviando; a tela já mostra o estado pedido
  #   { "failed" => "mensagem" }                # falhou há pouco (o tile fica em erro)
  #
  # Ponto sem nada em curso fica de fora do hash.
  class Inflight
    # Depois de confirmado pelo driver, quanto tempo esperar o aparelho avisar o valor
    # novo antes de desistir e mostrar o que ele disse por último. Erro fica à vista o mesmo tanto.
    SETTLE = 15.seconds
    STATEFUL = %w[on off toggle set select].freeze

    def self.for(points, now: Time.current)
      list = Array(points).compact
      return {} if list.empty?

      latest = ::Command.where(point_id: list.map(&:id), created_at: (now - ::Command::TTL)..)
                        .order(created_at: :desc).select(:id, :point_id, :command, :value, :status, :error, :created_at, :confirmed_at, :updated_at)
                        .to_a.group_by(&:point_id).transform_values(&:first)
      list.each_with_object({}) do |p, h|
        state = latest[p.id] && new(p, latest[p.id], now).state
        h[p.id] = state if state
      end
    end

    # Desenha o ponto já com o valor pedido (chave, texto e contagens batem com o que a
    # pessoa tocou); o registro volta ao valor de verdade no fim, sem gravar nada.
    def self.as_expected(point, state)
      real = point.value
      point.value = state["expect"]
      yield
    ensure
      point.value = real
    end

    def initialize(point, command, now)
      @point, @command, @now = point, command, now
    end

    def state
      return nil if answered?

      case @command.status
      when "pending", "sent" then pending
      when "confirmed" then pending if stateful? && @command.confirmed_at && @command.confirmed_at > @now - SETTLE
      when "failed" then { "failed" => @command.error.presence || true } if @command.updated_at > @now - SETTLE
      end
    end

    private

    # O aparelho já respondeu (o valor mudou depois do comando) ou não há o que esperar
    # (pediu o que já estava: ligar o que já está ligado).
    def answered?
      return true if @point.changed_at && @point.changed_at >= @command.created_at

      stateful? && !expect.nil? && same?(expect, current)
    end

    def pending = { "pending" => true, "expect" => expect }.compact

    def stateful? = STATEFUL.include?(@command.command)

    def current = @point.capability == "onoff" || @command.command.in?(%w[on off toggle]) ? on? : @point.value
    def on? = @point.value == true || @point.value == "open"

    def expect
      case @command.command
      when "on" then true
      when "off" then false
      when "toggle" then !on?
      when "set", "select" then @command.value
      end
    end

    def same?(a, b)
      return a == b if a == true || a == false

      a.to_s == b.to_s || (numeric?(a) && numeric?(b) && a.to_f == b.to_f)
    end

    def numeric?(v) = v.is_a?(Numeric) || v.to_s.match?(/\A-?\d+(\.\d+)?\z/)
  end
end
