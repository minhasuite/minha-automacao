module Points
  # Comando num ponto (ESQUEMA-V1 §4.3). Valida capacidade e argumento; no
  # driver `virtual` grava o valor direto no ponto. Quem pode mandar (papel x
  # risco) é checado antes, no controller.
  # ponytail: síncrono e sem tabela `commands`; a fila, o ack e a trilha chegam
  # com a F2/F3 (borda e drivers), mantendo esta interface.
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

    def self.call(point, command, value = nil) = new(point, command.to_s, value).call

    def initialize(point, command, value)
      @point = point
      @command = command
      @value = value
    end

    def call
      raise Error.new(:point_disabled, "Ponto desativado.") if @point.disabled || @point.device.disabled
      raise Error.new(:not_writable, "Este ponto só lê, não recebe comando.") unless @point.writable
      unless COMMANDS.fetch(@point.capability, []).include?(@command)
        raise Error.new(:unsupported_command, "Comando \"#{@command}\" não vale para #{@point.capability_label.downcase}.")
      end
      raise Error.new(:driver_unavailable, "O driver #{@point.device.driver} ainda não executa comandos.") unless @point.device.virtual?

      write(new_value)
      @point
    end

    private

    def new_value
      case @point.capability
      when "onoff" then { "on" => true, "off" => false }.fetch(@command) { !@point.value }
      when "dimmer", "setpoint" then number
      when "enum" then option
      when "text" then text
      when "gate" then @point.value == "open" ? "closed" : "open"
      end
    end

    def write(value)
      now = Time.current
      @point.changed_at = now unless value == @point.value
      @point.update!(value: value, quality: "good", reported_at: now)
    end

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
