module HelperTypes
  # Data e/ou hora (input_datetime do HA). Valor em texto ISO: "2026-10-30",
  # "18:30" ou "2026-10-30T18:30".
  class Datetime < Plugin
    MODES = { "datetime" => "Data e hora", "date" => "Só data", "time" => "Só hora" }.freeze
    FORMATS = { "datetime" => [ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/, "AAAA-MM-DDTHH:MM" ], "date" => [ /\A\d{4}-\d{2}-\d{2}\z/, "AAAA-MM-DD" ],
                "time" => [ /\A([01]\d|2[0-3]):[0-5]\d\z/, "HH:MM" ] }.freeze

    texts "pt-BR" => { modes: MODES, hints: FORMATS.transform_values(&:last), format: "Informe %{what} no formato %{hint}.",
                       missing: "Data ou hora inexistente.", date: "%d/%m/%Y", datetime: "%d/%m/%Y %H:%M" },
          en: { title: "Date and time", description: "A date, a time or both: wake-up time, back from vacation.",
                modes: { datetime: "Date and time", date: "Date only", time: "Time only" },
                hints: { datetime: "YYYY-MM-DDTHH:MM", date: "YYYY-MM-DD", time: "HH:MM" }, format: "Enter %{what} as %{hint}.",
                missing: "That date or time doesn't exist.", date: "%m/%d/%Y", datetime: "%m/%d/%Y %I:%M %p" },
          es: { title: "Fecha y hora", description: "Una fecha, una hora o las dos: hora de despertar, regreso de las vacaciones.",
                modes: { datetime: "Fecha y hora", date: "Solo fecha", time: "Solo hora" },
                hints: { datetime: "AAAA-MM-DDTHH:MM", date: "AAAA-MM-DD", time: "HH:MM" }, format: "Ingresa %{what} en el formato %{hint}.",
                missing: "Esa fecha u hora no existe.", date: "%d/%m/%Y", datetime: "%d/%m/%Y %H:%M" }

    describe key: "datetime", title: "Data e hora", icon: "calendar", capability: "datetime",
             description: "Uma data, uma hora ou as duas: hora de acordar, volta das férias."
    fields %i[mode]

    def self.assign(point, form)
      point.writable = true
      point.address = point.address.merge("mode" => form["mode"].presence_in(MODES.keys) || point.address["mode"] || "datetime")
    end

    def self.mode(point) = point.address["mode"].presence_in(MODES.keys) || "datetime"

    def self.initial_value(point) = { "date" => Date.current.iso8601, "time" => "00:00" }.fetch(mode(point)) { "#{Date.current.iso8601}T00:00" }

    def self.new_value(cmd)
      s = cmd.value.to_s.strip[0, 16]
      m = mode(cmd.point)
      format, = FORMATS[m]
      invalid!(text(:format, what: text("modes.#{m}").downcase, hint: text("hints.#{m}"))) unless format.match?(s)
      m == "date" ? Date.iso8601(s) : DateTime.iso8601(s) unless m == "time" # data que não existe (31/02) levanta
      s
    rescue ArgumentError
      invalid!(text(:missing))
    end

    def self.value_text(point)
      v = point.value.to_s
      return if v.empty? || mode(point) == "time"

      d = Time.zone.parse(v) or return
      I18n.l(d, format: text(mode(point) == "date" ? :date : :datetime))
    rescue ArgumentError
      nil
    end

    def self.summary(point) = text("modes.#{mode(point)}")
    def self.modes = labels(:modes, MODES)
  end
end
