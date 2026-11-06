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
      "text" => %w[set], "command" => %w[press], "gate" => %w[pulse], "datetime" => %w[set],
      "vacuum" => %w[start pause stop home clean_rooms wash_mop dry_mop empty locate],
      "speaker" => %w[announce speak routine sound play volume], "script" => %w[run], "color" => %w[set],
      # Pacote 1: mídia genérica (TV, Chromecast, Spotify…) e controle remoto (IR/RF aprendido).
      # ondaC2: grupo nativo de caixas (join = valor é o ponto de mídia que coordena).
      "media" => %w[on off resume pause next previous volume volume_up volume_down mute play_media join unjoin],
      "remote" => %w[send learn forget],
      # ondaC2 (C10): câmera move (PTZ), grava e toca áudio no alto-falante (o aparelho diz o que tem em `address.supports`).
      "stream" => %w[ptz record play_media]
    }.freeze
    PTZ_MOVES = %w[left right up down zoom_in zoom_out home].freeze
    MAX_RECORD_S = 600
    MAX_MEDIA = 500
    VACUUM_SETTINGS = %w[mode suction water route times].freeze
    MAX_SPEECH = 250

    # Mesmo `client_uuid` (reenvio do app offline) devolve o comando já criado.
    # `origin`: ponto cujo espelhamento gerou o comando (anti-eco do PointLink).
    # `run`: execução de automação que mandou (proteção contra laço, F6).
    def self.call(point, command, value = nil, source:, user: Current.user, client_uuid: nil, origin: nil, run: nil)
      existing = ::Command.find_by(client_uuid: client_uuid) if client_uuid.present?
      return existing if existing

      value = new(point, command.to_s, value).tap(&:new_value).value # valida (e normaliza) antes de criar
      Shadow.intercept!(point, command.to_s, value, source) # F10: em sombra, aparelho não recebe nada
      record = ::Command.create!(site: point.site, point: point, command: command.to_s, value: value, source: source,
                                 user: user, client_uuid: client_uuid.presence, origin_point_id: origin&.id,
                                 automation_run_id: run&.id)
      point.device.virtual? ? ExecuteCommandJob.perform_now(record.id) : ExecuteCommandJob.perform_later(record.id)
      record.reload
    end

    # Comandos que o ponto aceita: os do plugin, se for helper (F8e), ou os da capacidade.
    # Pacote 1: `address.supports` (lista) corta o que o aparelho não faz (TV sem volume exato, Cast sem ligar).
    def self.commands_for(point)
      return point.helper_type.commands(point) if point.helper_type

      list = COMMANDS.fetch(point.capability, [])
      # Automação como ponto: além de ligar/desligar, "run" roda agora (o automation.trigger do HA).
      list += %w[run] if AutomationPoints.automation?(point)
      (s = point.address["supports"]).is_a?(Array) ? list & s : list
    end

    # Comandos sem valor que a tela mostra como botões (helpers: contador, temporizador).
    def self.actions_for(point) = point.helper_type&.actions(point) || []

    # Pontos de ajuste do robô (papel → ponto irmão do mesmo aparelho).
    def self.vacuum_settings(point)
      point.device.points.select { |p| VACUUM_SETTINGS.include?(p.address["role"]) }.index_by { |p| p.address["role"] }
    end

    attr_reader :point, :command, :value
    # O plugin do helper pode trocar o argumento já validado (Pacote 3: o
    # código do alarme confere e sai antes de o comando ser gravado).
    attr_writer :value

    def initialize(point, command, value)
      @point = point
      @command = command
      @value = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
    end

    # Valor que o ponto passa a ter (levanta Error se o comando não serve).
    def new_value
      raise Error.new(:point_disabled, "Ponto desativado.") if @point.disabled || @point.device.disabled
      raise Error.new(:not_writable, "Este ponto só lê, não recebe comando.") unless @point.writable
      unless self.class.commands_for(@point).include?(@command)
        raise Error.new(:unsupported_command, "Comando \"#{@command}\" não vale para #{@point.capability_label.downcase}.")
      end
      raise Error.new(:driver_unavailable, "O driver #{@point.device.driver} ainda não executa comandos.") unless Drivers.supported?(@point.device)

      (plugin = @point.helper_type) ? plugin.new_value(self) : by_capability
    end

    # Valor pela regra da capacidade (o plugin de helper parte dele).
    def by_capability
      case @point.capability
      when "onoff" then @command == "run" ? nil : { "on" => true, "off" => false }.fetch(@command) { !@point.value }
      when "dimmer", "setpoint" then number
      when "enum" then option
      when "text" then text
      when "gate" then @point.value == "open" ? "closed" : "open"
      when "vacuum" then vacuum_args && @point.value
      when "speaker" then (@command == "volume" ? volume : speech) && @point.value
      when "color" then @value = Points::Color.normalize(@point, @value) # Lote 8
      when "media" then media_args && @point.value
      when "remote" then remote_args && @point.value
      when "stream" then stream_args && @point.value
      end
    end

    # Nomes dos códigos aprendidos de um controle remoto (address.codes = {nome → código}).
    def self.remote_buttons(point) = point.address["codes"].is_a?(Hash) ? point.address["codes"].keys : []

    private

    # Mídia: volume 0 a 100; mudo sim/não (sem valor = inverte); tocar = URI, playlist ou busca.
    def media_args
      case @command
      when "volume" then volume
      when "mute" then @value = @value.nil? || @value == "" ? !(@point.value.is_a?(Hash) && @point.value["muted"]) : ActiveModel::Type::Boolean.new.cast(@value)
      when "play_media" then media_url
      when "join"
        @value = @value.to_s.strip
        target = @point.site.points.find_by(id: @value, capability: "media")
        raise Error.new(:invalid_value, "Escolha a caixa que coordena o grupo.") if target.nil? || target.id == @point.id
      else @value = nil
      end
      true
    end

    def media_url
      @value = @value.to_s.strip
      raise Error.new(:invalid_value, "Informe o que tocar (endereço, playlist ou busca).") if @value.empty?
      raise Error.new(:invalid_value, "Texto longo demais (máximo #{MAX_MEDIA}).") if @value.length > MAX_MEDIA
    end

    # Câmera (ondaC2, C10): ptz = movimento (PTZ_MOVES) ou "preset:<token>"; record = segundos; play_media = áudio no alto-falante.
    def stream_args
      case @command
      when "ptz"
        @value = @value.to_s.strip
        raise Error.new(:invalid_value, "Movimento inválido.") unless PTZ_MOVES.include?(@value) || @value.match?(/\Apreset:[\w.\-]{1,64}\z/)
      when "record"
        n = Integer(@value.to_s.presence || 30, exception: false)
        raise Error.new(:invalid_value, "Gravar de 5 a #{MAX_RECORD_S} segundos.") unless n&.between?(5, MAX_RECORD_S)

        @value = n
      when "play_media" then media_url
      end
      true
    end

    # Controle remoto: enviar/esquecer um botão aprendido (pelo nome); aprender = nome do botão novo.
    def remote_args
      @value = @value.to_s.squish
      raise Error.new(:invalid_value, "Informe o nome do botão.") if @value.empty?
      raise Error.new(:invalid_value, "Nome longo demais (máximo 60).") if @value.length > 60
      return true if @command == "learn"
      raise Error.new(:invalid_value, "Botão \"#{@value}\" não foi aprendido.") unless self.class.remote_buttons(@point).include?(@value)

      true
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

    # Limpar cômodos: {rooms: [ids do mapa], mode:, suction:, water:, route:, times:} (ajustes opcionais).
    # Lote 9 (valor por texto de automação): o mesmo em JSON, ou só os cômodos
    # separados por vírgula, pelo id ou pelo nome no mapa ("5, Cozinha").
    def vacuum_args
      return true unless @command == "clean_rooms"

      args = room_args(@value)
      known = Array(@point.address["rooms"]).map { |r| r["id"].to_i }
      names = Array(@point.address["rooms"]).to_h { |r| [ r["name"].to_s.downcase, r["id"].to_i ] }
      rooms = Array(args["rooms"]).compact_blank.map { |r| Integer(r.to_s.strip, exception: false) || names[r.to_s.strip.downcase] }
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

    def room_args(value)
      return value.stringify_keys if value.is_a?(Hash)

      parsed = JSON.parse(value.to_s) if value.to_s.strip.start_with?("{")
      parsed.is_a?(Hash) ? parsed : { "rooms" => value.to_s.split(",") }
    rescue JSON::ParserError
      {}
    end

    def speech
      @value = @value.to_s.squish
      raise Error.new(:invalid_value, "Escreva o que a Echo deve falar.") if @value.empty?
      raise Error.new(:invalid_value, "Texto longo demais (máximo #{MAX_SPEECH}).") if @value.length > MAX_SPEECH

      @value
    end

    # Volume da Echo (G12) e da mídia: 0 a 100.
    def volume
      n = Integer(@value.to_s.split(/[.,]/).first, exception: false)
      raise Error.new(:invalid_value, "Volume de 0 a 100.") unless n&.between?(0, 100)

      @value = n
    end

    def text
      s = @value.to_s
      raise Error.new(:invalid_value, "Texto longo demais (máximo 255).") if s.length > 255

      s
    end
  end
end
