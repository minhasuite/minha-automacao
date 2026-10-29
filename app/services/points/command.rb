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
      "text" => %w[set], "command" => %w[press], "gate" => %w[pulse],
      "vacuum" => %w[start pause stop home clean_rooms wash_mop dry_mop empty locate], "speaker" => %w[announce speak]
    }.freeze
    VACUUM_SETTINGS = %w[mode suction water route times].freeze
    MAX_SPEECH = 250

    # Mesmo `client_uuid` (reenvio do app offline) devolve o comando já criado.
    # `origin`: ponto cujo espelhamento gerou o comando (anti-eco do PointLink).
    # `run`: execução de automação que mandou (proteção contra laço, F6).
    def self.call(point, command, value = nil, source:, user: Current.user, client_uuid: nil, origin: nil, run: nil)
      existing = ::Command.find_by(client_uuid: client_uuid) if client_uuid.present?
      return existing if existing

      value = new(point, command.to_s, value).tap(&:new_value).value # valida (e normaliza) antes de criar
      record = ::Command.create!(site: point.site, point: point, command: command.to_s, value: value, source: source,
                                 user: user, client_uuid: client_uuid.presence, origin_point_id: origin&.id,
                                 automation_run_id: run&.id)
      point.device.virtual? ? ExecuteCommandJob.perform_now(record.id) : ExecuteCommandJob.perform_later(record.id)
      record.reload
    end

    # Pontos de ajuste do robô (papel → ponto irmão do mesmo aparelho).
    def self.vacuum_settings(point)
      point.device.points.select { |p| VACUUM_SETTINGS.include?(p.address["role"]) }.index_by { |p| p.address["role"] }
    end

    attr_reader :value

    def initialize(point, command, value)
      @point = point
      @command = command
      @value = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
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
      when "vacuum" then vacuum_args && @point.value
      when "speaker" then speech && @point.value
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

    # Limpar cômodos: {rooms: [ids do mapa], mode:, suction:, water:, route:, times:} (ajustes opcionais).
    def vacuum_args
      return true unless @command == "clean_rooms"

      args = @value.is_a?(Hash) ? @value.stringify_keys : {}
      known = Array(@point.address["rooms"]).map { |r| r["id"].to_i }
      rooms = Array(args["rooms"]).compact_blank.map { |r| Integer(r.to_s, exception: false) }
      raise Error.new(:invalid_value, "Escolha ao menos um cômodo.") if rooms.empty?
      raise Error.new(:invalid_value, "Cômodo desconhecido no mapa do robô.") unless rooms.all? { |r| known.include?(r) }

      settings = self.class.vacuum_settings(@point)
      @value = { "rooms" => rooms.uniq }
      VACUUM_SETTINGS.each do |role|
        next if args[role].blank?
        raise Error.new(:invalid_value, "Opção inválida em #{settings[role]&.name || role}.") unless settings[role]&.option_values&.include?(args[role].to_s)

        @value[role] = args[role].to_s
      end
      @value
    end

    def speech
      @value = @value.to_s.squish
      raise Error.new(:invalid_value, "Escreva o que a Echo deve falar.") if @value.empty?
      raise Error.new(:invalid_value, "Texto longo demais (máximo #{MAX_SPEECH}).") if @value.length > MAX_SPEECH

      @value
    end

    def text
      s = @value.to_s
      raise Error.new(:invalid_value, "Texto longo demais (máximo 255).") if s.length > 255

      s
    end
  end
end
