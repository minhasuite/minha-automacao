module Automations
  module ConditionTypes
    # Há evento agora na agenda (F9), com filtro opcional no título.
    class CalendarCondition < Base
      describe key: "calendar", label: "Há evento agora",
               fields: [ f("point", :point, "Agenda", required: true), f("contains", :text, "Título contém (opcional)") ]

      def self.check(ev, c)
        p = ev.point!(c["point"])
        e = Calendars.current(p, ev.ctx.now, contains: c["contains"])
        [ e.present?, "#{p.name}: evento agora#{" com \"#{c['contains']}\"" if c['contains'].present?}", e ? "agora: #{e['summary']}" : "nenhum evento agora" ]
      end
    end
  end
end
