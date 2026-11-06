module Dashboards
  module Widgets
    # Agenda (ondaB2 B10; o `calendar` do HA): os próximos dias das agendas
    # (pontos `calendar`: Google/ICS e a Agenda local), agrupados por dia,
    # com uma cor por agenda e a faixa da semana no topo. Sem pontos = todas.
    class CalendarWidget < Base
      DAYS = 1..31
      describe type: "calendar", label: "Agenda", icon: "calendar", params: %w[days], binds: true
      texts en: { label: "Calendar", today: "Today", tomorrow: "Tomorrow", all_day: "All day", empty: "No events in the period.", bad_days: "days goes from 1 to 31",
                  no_calendar: "No calendar connected yet. Connect Google Calendar (or an ICS link) in Integrations.", connect: "Connect a calendar" },
            es: { label: "Agenda", today: "Hoy", tomorrow: "Mañana", all_day: "Todo el día", empty: "Sin eventos en el período.", bad_days: "days va de 1 a 31",
                  no_calendar: "Todavía no hay agenda conectada. Conecta Google Calendar (o un enlace ICS) en Integraciones.", connect: "Conectar una agenda" },
            "pt-BR" => { today: "Hoje", tomorrow: "Amanhã", all_day: "Dia inteiro", empty: "Nada na agenda no período.", bad_days: "days vai de 1 a 31",
                         no_calendar: "Nenhuma agenda ligada ainda. Ligue o Google Agenda (ou um link ICS) em Integrações.", connect: "Ligar uma agenda" }

      def self.errors(w) = w.key?("days") && !DAYS.cover?(w["days"]) ? [ text(:bad_days) ] : []
      def self.attrs(p, site = nil) = super.merge("days" => number(p[:days])&.to_i).compact
      def self.form = "web/dashboards/widget_forms/cards"

      def self.data(r, w, binds)
        cals = (binds.presence || r.points.select { |p| p.capability == "calendar" && !p.hidden && !p.disabled }).select { |p| p.capability == "calendar" }.first(8)
        zone = ActiveSupport::TimeZone[r.site.timezone] || Time.zone
        now = Time.current.in_time_zone(zone)
        today = now.to_date
        last = today + ((w["days"] || 7) - 1)
        events = cals.each_with_index.flat_map { |cal, i| Calendars.events(cal).filter_map { |e| event(e, cal, i, zone, now, today, last) } }
        days = events.sort_by { |e| [ e["day"], e["all_day"] ? 0 : 1, e["start"] ] }.group_by { |e| e["day"] }.map do |day, list|
          { "date" => day, "label" => day_label(Date.iso8601(day), today), "events" => list.first(12) }
        end
        week = (0..6).map do |n|
          d = today + n
          { "date" => d.iso8601, "dow" => I18n.l(d, format: "%a").first(3), "day" => d.day, "busy" => days.any? { |x| x["date"] == d.iso8601 } }
        end
        empty = cals.empty? ? text(:no_calendar) : text(:empty)
        [ { "point_ids" => cals.map(&:id), "days" => days, "week" => week, "empty" => empty, "no_calendar" => cals.empty?,
            "connect" => (text(:connect) if cals.empty? && SiteMembership.allowed?(r.role, :manage)),
            "connect_path" => (Rails.application.routes.url_helpers.new_site_integration_path(r.site.id, tipo: "calendar") if cals.empty?),
            "calendars" => cals.each_with_index.map { |c, i| { "name" => c.name, "color" => i } } }, [] ]
      end

      def self.event(e, cal, i, zone, now, today, last)
        start = Time.zone.parse(e["start"].to_s)&.in_time_zone(zone) or return
        finish = Time.zone.parse(e["end"].to_s)&.in_time_zone(zone) || start
        return if finish.to_date < today || start.to_date > last || (finish <= now && e["all_day"] != true)

        { "summary" => e["summary"].to_s.first(120), "start" => start.iso8601, "end" => finish.iso8601, "all_day" => e["all_day"] == true,
          "location" => e["location"].presence&.first(80), "calendar" => cal.name, "color" => i % 6, "day" => [ start.to_date, today ].max.iso8601,
          "time" => e["all_day"] == true ? text(:all_day) : "#{start.strftime('%H:%M')}–#{finish.strftime('%H:%M')}" }.compact
      end

      def self.day_label(date, today)
        return text(:today) if date == today
        return text(:tomorrow) if date == today + 1

        I18n.l(date, format: "%A, %-d %b").upcase_first
      end
    end
  end
end
