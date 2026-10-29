module Points
  # Comando num ponto (ESQUEMA-V1 §4.3/§4.4). Valida capacidade e argumento,
  # cria o `::Command` rastreável e o executa pelo ExecuteCommandJob: na hora
  # no driver `virtual` (sem aparelho, a tela responde instantâneo), na fila
  # nos drivers de verdade (F3). Quem pode mandar (papel x risco) é checado
  # antes, no controller.
  class Command
    class Error < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    COMMANDS = {
      "onoff" => %w[on off toggle], "dimmer" => %w[set], "setpoint" => %w[set], "enum" => %w[select],
      "text" => %w[set], "command" => %w[press], "gate" => %w[pulse]
    }.freeze

    # Mesmo `client_uuid` (reenvio do app offline) devolve o comando já criado.
    def self.call(point, command, value = nil, source:, user: Current.user, client_uuid: nil)
      existing = ::Command.find_by(client_uuid: client_uuid) if client_uuid.present?
      return existing if existing

      new(point, command.to_s, value).new_value # valida antes de criar
      record = ::Command.create!(site: point.site, point: point, command: command.to_s, value: value, source: source,
                                 user: user, client_uuid: client_uuid.presence)
      point.device.virtual? ? ExecuteCommandJob.perform_now(record.id) : ExecuteCommandJob.perform_later(record.id)
      record.reload
    end

    def initialize(point, command, value)
      @point = point
      @command = command
      @value = value
    end

    # Valor que o ponto passa a ter (levanta Error se o comando não serve).
    def new_value
      raise Error.new(:point_disabled, "Ponto desativado.") if @point.disabled || @point.device.disabled
      raise Error.new(:not_writable, "Este ponto só lê, não recebe comando.") unless @point.writable
      unless COMMANDS.fetch(@point.capability, []).include?(@command)
        raise Error.new(:unsupported_command, "Comando \"#{@command}\" não vale para #{@point.capability_label.downcase}.")
      end
      raise Error.new(:driver_unavailable, "O driver #{@point.device.driver} ainda não executa comandos.") unless Drivers.supported?(@point.device)

      case @point.capability
      when "onoff" then { "on" => true, "off" => false }.fetch(@command) { !@point.value }
      when "dimmer", "setpoint" then number
      when "enum" then option
      when "text" then text
      when "gate" then @point.value == "open" ? "closed" : "open"
      end
    end

    private

    def number
      n = BigDecimal(@value.to_s.tr(",", "."))
      if (@point.min && n < @point.min) || (@point.max && n > @point.max)
        raise Error.new(:invalid_value, "Valor fora da faixa permitida (#{@point.min&.to_s('F')} a #{@point.max&.to_s('F')}).")
      end

      @point.data_type == "integer" ? n.round.to_i : n.to_f
    rescue ArgumentError, TypeError
      raise Error.new(:invalid_value, "Informe um número.")
    end

    def option
      @value.to_s.presence_in(@point.option_values) or raise Error.new(:invalid_value, "Opção inválida.")
    end

    def text
      s = @value.to_s
      raise Error.new(:invalid_value, "Texto longo demais (máximo 255).") if s.length > 255

      s
    end
  end
end
