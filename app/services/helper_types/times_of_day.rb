module HelperTypes
  # Período do dia (tod do HA, ondaA1 A10): liga entre "depois de" e "antes
  # de", que podem ser HH:MM ou nascer/pôr do sol com deslocamento
  # ("sunset-30m"). Vira a meia-noite (22:00 → 06:00). Anda pelo relógio.
  class TimesOfDay < Plugin
    SPEC = /\A(?:(?<hm>[01]\d|2[0-3]):[0-5]\d|(?<sun>sunrise|sunset)(?<off>[+-]\d+[hms](?:\d+[ms])?)?)\z/

    describe key: "times_of_day", title: "Período do dia", icon: "clock", capability: "onoff",
             description: "Liga num período do dia, por horário ou pelo sol: noite (pôr do sol até 06:00), madrugada, horário comercial."
    fields %i[after before]
    texts "pt-BR" => { "form.after" => "Depois de", "form.before" => "Antes de", "hint.after" => "HH:MM, sunrise ou sunset, com deslocamento (sunset-30m).",
                       invalid: "Use HH:MM, sunrise ou sunset (com deslocamento opcional, ex.: sunset-30m).", sun: "O local precisa de latitude e longitude para usar o sol.",
                       summary: "de %{after} a %{before}" },
          en: { title: "Times of day", description: "Turns on during part of the day, by time or by the sun: night (sunset to 06:00), late night, business hours.",
                "form.after" => "After", "form.before" => "Before", "hint.after" => "HH:MM, sunrise or sunset, with an offset (sunset-30m).",
                invalid: "Use HH:MM, sunrise or sunset (optional offset, e.g. sunset-30m).", sun: "The site needs latitude and longitude to use the sun.",
                summary: "from %{after} to %{before}" },
          es: { title: "Período del día", description: "Se enciende en un período del día, por horario o por el sol: noche (puesta del sol hasta las 06:00), madrugada, horario comercial.",
                "form.after" => "Después de", "form.before" => "Antes de", "hint.after" => "HH:MM, sunrise o sunset, con desplazamiento (sunset-30m).",
                invalid: "Usa HH:MM, sunrise o sunset (desplazamiento opcional, ej.: sunset-30m).", sun: "El sitio necesita latitud y longitud para usar el sol.",
                summary: "de %{after} a %{before}" }

    def self.form_spec = [ [ :after, :text, { placeholder: "sunset" } ], [ :before, :text, { placeholder: "06:00" } ] ]

    def self.assign(point, form)
      after = form.fetch("after", point.address["after"]).to_s.strip.delete(" ")
      before = form.fetch("before", point.address["before"]).to_s.strip.delete(" ")
      point.data_type = "bool"
      point.writable = false
      point.address = point.address.merge("after" => after, "before" => before)
      return point.errors.add(:base, text(:invalid)) unless [ after, before ].all? { |s| s.match?(SPEC) }

      point.errors.add(:base, text(:sun)) if "#{after}#{before}".include?("sun") && !(point.site.latitude && point.site.longitude)
    end

    def self.clocked? = true
    def self.initial_value(point) = on_at?(point, Time.current)
    def self.tick(point, now) = (v = on_at?(point, now)) == point.value ? nil : point.report!(v)

    # Momento do dia (local) do texto ("06:00", "sunset-30m").
    def self.at(spec, site, day, zone)
      m = SPEC.match(spec.to_s) or return
      return zone.parse("#{day} #{spec}") if m[:hm]

      base = Sun.at(m[:sun], day, site.latitude, site.longitude, zone) or return
      base + Automations::Dsl.seconds(m[:off].to_s.delete_prefix("+")).to_i
    end

    def self.on_at?(point, now)
      zone = ActiveSupport::TimeZone[point.site.timezone]
      local = now.in_time_zone(zone)
      start = at(point.address["after"], point.site, local.to_date, zone)
      stop = at(point.address["before"], point.site, local.to_date, zone)
      return false unless start && stop

      start <= stop ? local >= start && local < stop : local >= start || local < stop
    end

    def self.summary(point) = text(:summary, after: point.address["after"], before: point.address["before"])
  end
end
