module HelperTypes
  # Agenda local (local_calendar do HA, ondaA1 A11): eventos criados aqui
  # (tela Agenda, automação "Criar evento", API), com repetição diária,
  # semanal, mensal ou anual. Guarda a lista em `address["local"]` e gera o
  # mesmo `address["events"]` das agendas ICS (Calendars), então gatilho,
  # condição, "Ler eventos" e painel funcionam igual. A expansão usa o
  # próprio leitor de ICS (cada evento vira um VEVENT com RRULE).
  class LocalCalendar < Plugin
    REPEATS = %w[none daily weekly monthly yearly].freeze
    MAX = 500

    describe key: "local_calendar", title: "Agenda local", icon: "calendar", capability: "calendar",
             description: "Agenda da casa criada aqui (com repetição): coleta de lixo, rodízio, aulas. Serve a gatilhos, condições e painéis como qualquer agenda."
    texts "pt-BR" => { summary: "%{n} eventos", untitled: "(sem título)", bad: "Evento inválido: informe título, início e fim depois do início.", full: "A agenda já tem %{max} eventos.",
                       "repeat.none" => "Não repete", "repeat.daily" => "Todo dia", "repeat.weekly" => "Toda semana", "repeat.monthly" => "Todo mês", "repeat.yearly" => "Todo ano" },
          en: { title: "Local calendar", description: "House calendar created here (with repeats): trash day, rotation, classes. Works with triggers, conditions and dashboards like any calendar.",
                summary: "%{n} events", untitled: "(untitled)", bad: "Invalid event: enter a title, a start and an end after the start.", full: "The calendar already has %{max} events.",
                "repeat.none" => "Does not repeat", "repeat.daily" => "Every day", "repeat.weekly" => "Every week", "repeat.monthly" => "Every month", "repeat.yearly" => "Every year" },
          es: { title: "Agenda local", description: "Agenda de la casa creada aquí (con repetición): recolección de basura, turnos, clases. Sirve a disparadores, condiciones y paneles como cualquier agenda.",
                summary: "%{n} eventos", untitled: "(sin título)", bad: "Evento inválido: indica título, inicio y fin después del inicio.", full: "La agenda ya tiene %{max} eventos.",
                "repeat.none" => "No se repite", "repeat.daily" => "Todos los días", "repeat.weekly" => "Todas las semanas", "repeat.monthly" => "Todos los meses", "repeat.yearly" => "Todos los años" }

    def self.assign(point, _form)
      point.data_type = "json"
      point.writable = false
      point.address = point.address.merge("local" => Array(point.address["local"]))
    end

    def self.summary(point) = text(:summary, n: Array(point.address["local"]).size)
    def self.clocked? = true

    # A cada hora refaz a janela (evento repetido entra quando chega a vez).
    def self.tick(point, now) = (rebuild!(point, now) if now.min.zero?)
    def self.initial_value(_point) = nil

    def self.zone(point) = ActiveSupport::TimeZone[point.site.timezone]

    # {summary, start, end, all_day, location, description, repeat} → guardado; levanta ArgumentError.
    def self.add_event!(point, attrs)
      list = Array(point.address["local"])
      raise ArgumentError, text(:full, max: MAX) if list.size >= MAX

      e = normalize(point, attrs)
      point.update!(address: point.address.merge("local" => list + [ e ]))
      rebuild!(point)
      e
    end

    def self.remove_event!(point, uid)
      point.update!(address: point.address.merge("local" => Array(point.address["local"]).reject { |e| e["uid"] == uid }))
      rebuild!(point)
    end

    def self.normalize(point, attrs)
      a = attrs.to_h.stringify_keys
      z = zone(point)
      all_day = ActiveModel::Type::Boolean.new.cast(a["all_day"]) == true
      start = parse(a["start"], z)
      stop = parse(a["end"].presence || (start && (all_day ? start + 1.day : start + 1.hour)), z)
      start = start&.beginning_of_day if all_day
      stop = stop&.beginning_of_day if all_day && stop && stop.seconds_since_midnight.positive? && stop.to_date > start.to_date
      stop = start + 1.day if all_day && stop && start && stop <= start
      summary = a["summary"].to_s.squish.first(255)
      raise ArgumentError, text(:bad) if summary.empty? || start.nil? || stop.nil? || stop <= start

      { "uid" => SecureRandom.uuid, "summary" => summary, "start" => start.iso8601, "end" => stop.iso8601, "all_day" => all_day,
        "location" => a["location"].to_s.squish.first(255).presence, "description" => a["description"].to_s.first(2000).presence,
        "repeat" => a["repeat"].to_s.presence_in(REPEATS) || "none" }.compact
    end

    def self.parse(v, zone)
      return v.in_time_zone(zone) if v.respond_to?(:in_time_zone) && !v.is_a?(String)

      v.to_s.strip.empty? ? nil : zone.parse(v.to_s)
    rescue ArgumentError
      nil
    end

    # Eventos guardados → ICS → os eventos da janela (Calendars), e o valor.
    def self.rebuild!(point, now = Time.current)
      from, to = Calendars.window(now)
      Calendars.store!(point.reload, Calendars.parse_ics(ics(point), zone(point), from: from, to: to), now)
    end

    def self.ics(point)
      fmt = ->(iso, all_day) { t = Time.zone.parse(iso).in_time_zone(zone(point)); all_day ? ";VALUE=DATE:#{t.strftime('%Y%m%d')}" : ";TZID=#{point.site.timezone}:#{t.strftime('%Y%m%dT%H%M%S')}" }
      esc = ->(s) { s.to_s.gsub("\\", "\\\\\\").gsub(/([,;])/, '\\\\\1').gsub("\n", "\\n") }
      events = Array(point.address["local"]).map do |e|
        [ "BEGIN:VEVENT", "UID:#{e['uid']}", "SUMMARY:#{esc.(e['summary'])}", "DTSTART#{fmt.(e['start'], e['all_day'])}", "DTEND#{fmt.(e['end'], e['all_day'])}",
          ("LOCATION:#{esc.(e['location'])}" if e["location"]), ("RRULE:FREQ=#{e['repeat'].upcase}" if e["repeat"].present? && e["repeat"] != "none"), "END:VEVENT" ].compact
      end
      ([ "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Minha Automação//Agenda local//PT", "X-WR-CALNAME:#{esc.(point.name)}" ] + events.flatten + [ "END:VCALENDAR" ]).join("\r\n")
    end
  end
end
