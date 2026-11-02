module HelperTypes
  # Painel de alarme (o `manual` do HA / Alarmo), genérico: cada modo (em
  # casa, ausente, noite, férias; registro em `MODES`) tem o seu conjunto de
  # sensores, atraso de saída e de entrada. Código (PIN) guardado só em
  # bcrypt; o comando com código não grava o código na tabela de comandos.
  #
  # Valor: disarmed, arming (contando a saída), armed_<modo>, pending
  # (contando a entrada) ou triggered. O painel não toca nada sozinho: sirene,
  # aviso e luz são automações com o gatilho "Alarme mudou" (nada de aparelho
  # fixo aqui). Os tempos são HelperTimerJob com carimbo (`address.stamp`),
  # como o temporizador: sobrevivem a reinício e job velho não age.
  class AlarmPanel < Plugin
    # Modo novo = uma linha (estado → rótulo e comando que arma).
    MODES = {
      "armed_home" => { label: "Em casa", command: "arm_home" },
      "armed_away" => { label: "Ausente", command: "arm_away" },
      "armed_night" => { label: "Noite", command: "arm_night" },
      "armed_vacation" => { label: "Férias", command: "arm_vacation" }
    }.freeze
    BASE_STATES = { "disarmed" => "Desarmado", "arming" => "Armando", "pending" => "Entrada: desarme agora", "triggered" => "Disparado" }.freeze
    CODE = /\A\d{4,8}\z/
    MAX_DELAY = 10.minutes.to_i
    MAX_SENSORS = 100

    describe key: "alarm_panel", title: "Painel de alarme", icon: "shield-check", capability: "enum",
             description: "Armar em casa, ausente, noite ou férias, cada modo com os seus sensores, atrasos e código. A sirene é uma automação."
    fields [ :code, :code_arm, :trigger_time, { modes: {} } ]
    texts "pt-BR" => { modes: MODES.transform_values { |m| m[:label] }, states: BASE_STATES, armed: "Armado (%{mode})", arm: "Armar: %{mode}",
                       disarm: "Desarmar", panic: "Disparar (pânico)", code_size: "O código precisa ter de 4 a 8 números.", code_missing: "Defina um código.",
                       bad_trigger: "Tempo disparado inválido.", no_mode: "Ligue ao menos um modo.", delays: "%{mode}: atrasos de 0 a 10 min (ex.: 30s, 1m).",
                       open_sensors: "Sensores abertos: %{names}.", no_code: "Painel sem código.", wrong_code: "Código incorreto.",
                       commands_only: "O painel muda só pelos comandos (armar e desarmar com código).", summary: "modos: %{modes}" },
          en: { title: "Alarm panel", description: "Arm for home, away, night or vacation, each mode with its own sensors, delays and code. The siren is an automation.",
                modes: { armed_home: "Home", armed_away: "Away", armed_night: "Night", armed_vacation: "Vacation" },
                states: { disarmed: "Disarmed", arming: "Arming", pending: "Entry: disarm now", triggered: "Triggered" },
                armed: "Armed (%{mode})", arm: "Arm: %{mode}", disarm: "Disarm", panic: "Trigger (panic)",
                code_size: "The code must be 4 to 8 digits.", code_missing: "Set a code.", bad_trigger: "Invalid triggered time.",
                no_mode: "Turn on at least one mode.", delays: "%{mode}: delays from 0 to 10 min (e.g. 30s, 1m).",
                open_sensors: "Open sensors: %{names}.", no_code: "The panel has no code.", wrong_code: "Wrong code.",
                commands_only: "The panel only changes through commands (arm and disarm with the code).", summary: "modes: %{modes}" },
          es: { title: "Panel de alarma", description: "Arma en casa, ausente, noche o vacaciones, cada modo con sus sensores, retardos y código. La sirena es una automatización.",
                modes: { armed_home: "En casa", armed_away: "Ausente", armed_night: "Noche", armed_vacation: "Vacaciones" },
                states: { disarmed: "Desarmado", arming: "Armando", pending: "Entrada: desarma ahora", triggered: "Disparado" },
                armed: "Armado (%{mode})", arm: "Armar: %{mode}", disarm: "Desarmar", panic: "Disparar (pánico)",
                code_size: "El código debe tener de 4 a 8 números.", code_missing: "Define un código.", bad_trigger: "Tiempo disparado no válido.",
                no_mode: "Activa al menos un modo.", delays: "%{mode}: retardos de 0 a 10 min (ej.: 30s, 1m).",
                open_sensors: "Sensores abiertos: %{names}.", no_code: "El panel no tiene código.", wrong_code: "Código incorrecto.",
                commands_only: "El panel solo cambia con comandos (armar y desarmar con código).", summary: "modos: %{modes}" }

    def self.mode_label(state) = text("modes.#{state}")
    def self.states = BASE_STATES.to_h { |k, _| [ k, text("states.#{k}") ] }.merge(MODES.to_h { |k, _| [ k, text(:armed, mode: mode_label(k).downcase) ] })
    def self.mode_commands = MODES.to_h { |state, m| [ m[:command], state ] }

    def self.assign(point, form)
      point.writable = true
      point.data_type = "enum"
      point.icon ||= icon
      point.risk = "sensitive" if point.risk.blank? || point.risk == "normal"
      point.options = states.keys
      a = point.address.except("code_digest")
      code = form["code"].to_s.strip
      if code.present?
        return point.errors.add(:base, text(:code_size)) unless code.match?(CODE)

        a["code_digest"] = BCrypt::Password.create(code).to_s
      elsif point.address["code_digest"]
        a["code_digest"] = point.address["code_digest"]
      end
      point.errors.add(:base, text(:code_missing)) unless a["code_digest"]
      a["code_arm"] = ActiveModel::Type::Boolean.new.cast(form["code_arm"]) || false
      a["trigger_s"] = Automations::Dsl.seconds(form["trigger_time"].presence || "3m") || point.errors.add(:base, text(:bad_trigger))
      modes = assign_modes(point, form["modes"].to_h)
      point.errors.add(:base, text(:no_mode)) if modes.empty?
      a["modes"] = modes
      a["sources"] = modes.values.flat_map { |m| m["sensors"] }.uniq
      point.address = a
    end

    def self.assign_modes(point, raw)
      MODES.keys.each_with_object({}) do |state, out|
        m = raw[state].to_h.stringify_keys
        next unless ActiveModel::Type::Boolean.new.cast(m["enabled"])

        ids = Array(m["sensors"]).compact_blank.uniq.first(MAX_SENSORS)
        sensors = point.site.points.where(id: ids).where.not(id: point.id).pluck(:id)
        exit_s = Automations::Dsl.seconds(m["exit"].presence || "0s")
        entry_s = Automations::Dsl.seconds(m["entry"].presence || "0s")
        unless exit_s&.between?(0, MAX_DELAY) && entry_s&.between?(0, MAX_DELAY)
          point.errors.add(:base, text(:delays, mode: mode_label(state)))
          next
        end
        out[state] = { "sensors" => sensors, "exit_s" => exit_s, "entry_s" => entry_s }
      end
    end

    def self.initial_value(_point) = "disarmed"
    def self.command_labels = MODES.to_h { |s, m| [ m[:command], text(:arm, mode: mode_label(s).downcase) ] }.merge("disarm" => text(:disarm), "trigger" => text(:panic))
    def self.commands(point) = configured(point).map { |s| MODES[s][:command] } + %w[disarm trigger]
    def self.configured(point) = MODES.keys & point.address["modes"].to_h.keys
    def self.value_text(point) = states[point.value.to_s]
    def self.armed?(value) = MODES.key?(value.to_s)

    # Validação do comando (o código confere aqui e some do comando).
    def self.new_value(cmd)
      point = cmd.point
      state = mode_commands[cmd.command]
      needs_code = cmd.command == "disarm" || (state && point.address["code_arm"])
      check_code!(point, cmd.value) if needs_code
      cmd.value = nil
      return "disarmed" if cmd.command == "disarm"
      return "triggered" if cmd.command == "trigger"

      open = active_sensors(point, state)
      invalid!(text(:open_sensors, names: open.map(&:name).join(", "))) if open.any?
      exit_s(point, state).positive? ? "arming" : state
    end

    def self.check_code!(point, code)
      digest = point.address["code_digest"] or invalid!(text(:no_code))
      ok = code.to_s.match?(CODE) && BCrypt::Password.new(digest).is_password?(code.to_s)
      invalid!(text(:wrong_code)) unless ok
    end

    def self.execute(point, command, _value)
      case command
      when "disarm" then set!(point, "disarmed", target: nil)
      when "trigger" then trigger!(point, by: [ "Pânico" ])
      else
        state = mode_commands.fetch(command)
        wait = exit_s(point, state)
        wait.positive? ? set!(point, "arming", target: state, wait: wait) : set!(point, state, target: state)
      end
    end

    # Sensor do modo armado mudou (HelperTypes.on_change pelas `sources`).
    def self.refresh!(point)
      return unless armed?(point.value)

      open = active_sensors(point, point.value)
      return if open.empty?

      entry = mode(point, point.value)["entry_s"].to_i
      names = open.map(&:name)
      entry.positive? ? set!(point, "pending", target: point.value, wait: entry, by: names) : trigger!(point, by: names)
    end

    # Fim de um tempo (HelperTimerJob): só se ainda for o mesmo carimbo.
    def self.finish_due!(point, stamp)
      return unless point.address["stamp"] == stamp

      target = point.address["target"]
      case point.value
      when "arming" then set!(point, target, target: target)
      when "pending" then trigger!(point, by: point.attrs.to_h["tripped_by"])
      when "triggered" then set!(point, target || "disarmed", target: target)
      end
    end

    def self.trigger!(point, by:)
      target = armed?(point.value) ? point.value : point.address["target"]
      set!(point, "triggered", target: target, wait: point.address["trigger_s"].to_i, by: by)
    end

    def self.set!(point, state, target:, wait: 0, by: nil)
      a = point.address.except("stamp", "until").merge("target" => target).compact
      if wait.positive?
        a["until"] = (Time.current + wait).iso8601(3)
        a["stamp"] = a["until"]
        HelperTimerJob.set(wait: wait.seconds).perform_later(point.id, a["stamp"])
      end
      point.address = a
      point.report!(state)
      point.report_attrs!(point.attrs.to_h.except("tripped_by").merge("tripped_by" => by, "until" => a["until"]).compact)
    end

    def self.mode(point, state) = point.address.dig("modes", state).to_h
    def self.exit_s(point, state) = mode(point, state)["exit_s"].to_i

    def self.active_sensors(point, state)
      ids = mode(point, state)["sensors"]
      return [] if ids.blank?

      point.site.points.where(id: ids, quality: "good").select { |s| active?(s) }
    end

    # Disparado = ligado, aberto, movimento (valor verdadeiro ou "open").
    def self.active?(sensor) = sensor.value == true || sensor.value.to_s == "open"

    def self.reset!(point) = set!(point, "disarmed", target: nil)

    # Escrever o valor direto (POST /points/:id/value, ferramentas) pularia o código.
    def self.check(_point, _value) = invalid!(text(:commands_only))

    def self.public_address(point) = point.address.except("code_digest").merge("has_code" => point.address["code_digest"].present?)

    def self.summary(point)
      modes = configured(point).map { |s| "#{mode_label(s).downcase} (#{mode(point, s)['sensors'].size})" }
      text(:summary, modes: modes.join(", "))
    end
  end
end
