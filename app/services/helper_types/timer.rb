module HelperTypes
  # Temporizador (timer do HA). Valor: idle (parado), active (contando),
  # paused (pausado) ou finished (terminou: o gatilho "Ponto mudou para
  # Terminou" é o evento de fim). `address`: duration_s, finishes_at (ISO,
  # contando) e remaining_s (pausado). O fim é um HelperTimerJob agendado no
  # Solid Queue com o carimbo `finishes_at`, como as esperas da F6: sobrevive
  # a reinício e job velho (pausou, cancelou, reiniciou) não termina nada.
  class Timer < Plugin
    COMMANDS = %w[start pause cancel finish].freeze
    LABELS = { "start" => "Iniciar temporizador", "pause" => "Pausar temporizador", "cancel" => "Cancelar temporizador",
               "finish" => "Terminar temporizador" }.freeze
    MAX = 7.days.to_i

    describe key: "timer", title: "Temporizador", icon: "clock", capability: "timer",
             description: "Conta um tempo e avisa quando acaba: desligar a rega em 20 min. Sobrevive a reinício."
    fields %i[duration]

    def self.assign(point, form)
      point.writable = true
      point.data_type = "enum"
      sec = Automations::Dsl.seconds(form["duration"].presence || point.address["duration_s"] || "")
      point.errors.add(:base, "Duração inválida (use 30s, 5m, 1h30m; até 7 dias).") unless sec&.between?(1, MAX)
      point.address = point.address.merge("duration_s" => sec)
    end

    def self.initial_value(_point) = "idle"
    def self.commands(_point) = COMMANDS
    def self.command_labels = LABELS

    def self.actions(point)
      { "active" => %w[pause cancel finish], "paused" => %w[start cancel] }.fetch(point.value, %w[start])
    end

    def self.value_text(point)
      case point.value
      when "active" then "Contando, termina às #{I18n.l(Time.zone.parse(point.address['finishes_at']), format: '%H:%M:%S')}" if point.address["finishes_at"]
      when "paused" then "Pausado, faltam #{Automations::Dsl.duration_label(point.address['remaining_s'].to_i)}"
      end
    end

    # Estado depois do comando (a validação; quem agenda é o `execute`).
    def self.new_value(cmd)
      if cmd.command == "start"
        duration(cmd.value)
        return "active"
      end

      { "pause" => cmd.point.value == "active" ? "paused" : cmd.point.value, "cancel" => "idle",
        "finish" => cmd.point.value.in?(%w[active paused]) ? "finished" : cmd.point.value }.fetch(cmd.command)
    end

    # Duração do "iniciar": a do comando (ex.: "5m") ou nil (a do cadastro).
    def self.duration(raw)
      return if raw.blank?

      sec = Automations::Dsl.seconds(raw)
      sec&.between?(1, MAX) ? sec : invalid!("Duração inválida (use 30s, 5m, 1h30m).")
    end

    def self.execute(point, command, value)
      state = Points::Command.new(point, command, value).new_value
      a = point.address.except("finishes_at", "remaining_s")
      case command
      when "start"
        sec = duration(value) || (point.value == "paused" && point.address["remaining_s"]) || a["duration_s"]
        at = Time.current + sec.to_i
        a["finishes_at"] = at.iso8601(3)
        HelperTimerJob.set(wait_until: at).perform_later(point.id, a["finishes_at"])
      when "pause"
        a["remaining_s"] = remaining(point) if point.value == "active"
        a = point.address if point.value == "paused"
      end
      point.address = a
      point.report!(state)
    end

    # Job do fim: só termina se ainda for o mesmo agendamento.
    def self.finish_due!(point, stamp)
      execute(point, "finish", nil) if point.value == "active" && point.address["finishes_at"] == stamp
    end

    def self.remaining(point)
      at = point.address["finishes_at"] or return point.address["remaining_s"]
      [ (Time.zone.parse(at) - Time.current).ceil, 0 ].max
    end

    def self.reset!(point) = execute(point, "cancel", nil)

    def self.summary(point) = "duração #{Automations::Dsl.duration_label(point.address['duration_s'].to_i)}"
  end
end
