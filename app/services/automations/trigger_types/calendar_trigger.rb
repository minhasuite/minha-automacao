module Automations
  module TriggerTypes
    # Evento de agenda começou/terminou (F9), com filtro no título e
    # antecedência (-15m) ou atraso (10m). Relógio: a cada minuto olha os
    # eventos guardados no ponto `calendar` (Calendars).
    class CalendarTrigger < Base
      describe key: "calendar", label: "Evento da agenda", defaults: { "event" => "start" },
               fields: [ f("point", :point, "Agenda", required: true, en: "Calendar", es: "Calendario"),
                         f("event", :select, "Quando o evento", required: true, options: -> { events }, en: "When the event", es: "Cuando el evento"),
                         f("contains", :text, "Título contém (opcional)", en: "Title contains (optional)", es: "El título contiene (opcional)"),
                         f("offset", :duration, "Antes (-15m) ou depois (10m)", en: "Before (-15m) or after (10m)", es: "Antes (-15m) o después (10m)") ]
      texts "pt-BR" => { events: { start: "Começou", end: "Terminou" }, title: "Evento %{event}" },
            en: { label: "Calendar event", events: { start: "Started", end: "Ended" }, title: "Event %{event}" },
            es: { label: "Evento del calendario", events: { start: "Comenzó", end: "Terminó" }, title: "Evento %{event}" }

      def self.events = %w[start end].index_with { |k| text("events.#{k}") }

      def self.clock = true

      def self.title(t) = "#{text(:title, event: events.fetch(t['event'], '').downcase)}#{" (\"#{t['contains']}\")" if t['contains'].present?}"

      def self.due?(t, site, local)
        point = site.points.find_by(id: t["point"], capability: "calendar") or return false
        shift = Dsl.seconds(t["offset"]).to_i
        minute = local.strftime("%Y-%m-%d %H:%M")
        Calendars.events(point).any? do |e|
          Calendars.match?(e, t["contains"]) && e[t["event"]] &&
            (Time.zone.parse(e[t["event"]]) + shift).in_time_zone(local.time_zone).strftime("%Y-%m-%d %H:%M") == minute
        end
      end
    end
  end
end
