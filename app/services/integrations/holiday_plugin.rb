module Integrations
  # Feriados (catalogo): feriados nacionais (e do estado, se informado) como
  # agenda, pela base aberta Nager.Date (grátis, sem chave, 100+ países).
  # Vira um ponto `calendar`: os gatilhos e condições de agenda já servem
  # ("é feriado hoje?").
  class HolidayPlugin < SchemaPlugin
    describe key: "holiday", title: "Feriados", icon: "calendar",
             description: "Feriados do país (e do estado) como agenda, para automações do tipo \"em dia de feriado, não abrir a cortina às 6h\"."
    texts "pt-BR" => { fields: { country: "País (código de 2 letras)", subdivision: "Estado (opcional)" }, hints: { country: "BR", subdivision: "ex. BR-SP" },
                       points: { holidays: "Feriados" }, bad_country: "País sem feriados na base: %{country}." },
          en: { title: "Holidays", description: "The country's (and state's) public holidays as a calendar, for automations like \"on holidays, don't open the blinds at 6 am\".",
                fields: { country: "Country (2-letter code)", subdivision: "State (optional)" }, hints: { country: "US", subdivision: "e.g. US-CA" },
                points: { holidays: "Holidays" }, bad_country: "Country without holidays in the database: %{country}." },
          es: { title: "Feriados", description: "Los feriados del país (y de la provincia) como agenda, para automatizaciones como \"en feriado, no abrir la cortina a las 6\".",
                fields: { country: "País (código de 2 letras)", subdivision: "Provincia (opcional)" }, hints: { country: "ES", subdivision: "ej. ES-MD" },
                points: { holidays: "Feriados" }, bad_country: "País sin feriados en la base: %{country}." }
    field :country, required: true, default: "BR"
    field :subdivision

    URL = "https://date.nager.at/api/v3/PublicHolidays".freeze

    class << self
      def year(country, year)
        res = SafeHttp.get("#{URL}/#{year}/#{CGI.escape(country)}", timeout: 15)
        raise Integrations::Error, text(:bad_country, country: country) unless res.status == 200

        JSON.parse(res.body)
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, "Nager.Date: #{e.message}"
      end

      # Eventos de dia inteiro dentro da janela das agendas (ontem até +31 dias).
      def events(integration, now = Time.current)
        country = conf(integration, :country).to_s.upcase
        sub = integration.settings["subdivision"].to_s.upcase.presence
        zone = ActiveSupport::TimeZone[integration.site.timezone] || Time.zone
        from, to = Calendars.window(now)
        list = (from.year..to.year).flat_map { |y| year(country, y) }
        list.select { |h| h["global"] != false || (sub && Array(h["counties"]).include?(sub)) }.filter_map do |h|
          day = zone.parse(h["date"].to_s) or next
          next unless day >= from.beginning_of_day && day < to

          { "summary" => h["localName"].presence || h["name"], "start" => day.iso8601, "end" => (day + 1.day).iso8601, "all_day" => true }
        end.uniq { |e| [ e["start"], e["summary"] ] }
      end

      def entries(integration)
        events(integration)
        [ entry(id: "holiday:#{integration.id}", name: integration.name, manufacturer: nil, poll_s: 86_400,
                points: [ point("holidays", "calendar", history: "none") ]) ]
      end

      def poll(device)
        point = device.points.find { |p| p.capability == "calendar" } or return
        Calendars.store!(point, events(device.integration))
        device.update_columns(status: "online", last_seen_at: Time.current)
      end
    end
  end
end
