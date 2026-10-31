module Automations
  module ActionTypes
    # "Ler eventos da agenda" (Lote 1, `calendar.get_events` do HA): os
    # eventos guardados no ponto `calendar` (integração de agenda da F9) que
    # tocam a janela [agora + a partir de, + durante), com filtro no título.
    # Resposta: {events: [{summary, start, end, all_day, location}], count,
    # titles}; no texto `{% for e in agenda.events %}`, na expressão `agenda.count > 0`.
    class CalendarEventsAction < Base
      # Só lê os eventos guardados no ponto.
      def self.shadow_safe?(_e, _node) = true

      describe key: "calendar_events", label: "Ler eventos da agenda", defaults: { "within" => "24h", "response_variable" => "agenda" },
               fields: [ f("point", :point, "Agenda", required: true), f("start", :duration, "A partir de (ex.: 0m, -1h, 2h)"),
                         f("within", :duration, "Durante (ex.: 24h)", required: true), f("contains", :text, "Título contém (opcional)") ]
      returns "{events: [{summary, start, end, all_day, location}], count, titles}"

      def self.call(e, _path, node)
        point = e.ctx.point(node["point"]) or raise Engine::Failure, "Agenda removida do local."
        raise Engine::Failure, "#{point.name} não é uma agenda." unless point.capability == "calendar"

        from = e.ctx.now + Dsl.seconds(node["start"]).to_i
        to = from + Dsl.seconds(node["within"]).to_i
        events = Calendars.events(point).select do |ev|
          Calendars.match?(ev, node["contains"]) && Time.zone.parse(ev["start"]) < to && Time.zone.parse(ev["end"] || ev["start"]) >= from
        end
        respond(e, node, { "events" => events, "count" => events.size, "titles" => events.pluck("summary").join(", ") })
        [ "Ler agenda #{point.name}", "ok", "#{events.size} evento(s) até #{I18n.l(to, format: '%d/%m %H:%M')} em #{node['response_variable']}" ]
      end
    end
  end
end
