module Dashboards
  module Widgets
    # Uso de IA do local (o `sensor.ia_historico` do HA, aqui pelo AiCall): chamadas hoje e no mês, falhas
    # em 30 dias e, para quem administra (técnico ou dono, como em Configurações → IA), o gasto estimado do
    # mês. Abaixo, as automações que mais chamaram a IA em 30 dias. Nunca há prompt nem resposta (o AiCall
    # não guarda).
    class AiUsageWidget < Base
      TOP = 6
      describe type: "ai_usage", label: "Uso de IA", icon: "sparkles"
      texts en: { label: "AI usage", today: "Calls today", month: "This month", errors: "Failures (30 days)", cost: "Spent this month",
                  by_automation: "By automation (30 days)", empty: "No AI calls yet." },
            es: { label: "Uso de IA", today: "Llamadas hoy", month: "En el mes", errors: "Fallas (30 días)", cost: "Gasto del mes",
                  by_automation: "Por automatización (30 días)", empty: "Todavía no hay llamadas a la IA." },
            "pt-BR" => { today: "Chamadas hoje", month: "No mês", errors: "Falhas (30 dias)", cost: "Gasto no mês",
                         by_automation: "Por automação (30 dias)", empty: "Nenhuma chamada à IA ainda." }

      def self.data(r, _w, _binds)
        tz = r.site.timezone
        calls = AiCall.where(site_id: [ r.site.id, nil ])
        today = Time.current.in_time_zone(tz).beginning_of_day
        month = Time.current.in_time_zone(tz).beginning_of_month
        recent = calls.where(created_at: 30.days.ago..)
        admin = SiteMembership.allowed?(r.role, :manage)
        items = [ { "key" => "today", "label" => text(:today), "value" => calls.where(created_at: today..).count },
                  { "key" => "month", "label" => text(:month), "value" => calls.where(created_at: month..).count },
                  { "key" => "errors", "label" => text(:errors), "value" => recent.where(status: "error").count, "bad" => true } ]
        if admin
          cost = calls.charged.where(created_at: month..).sum(:cost).to_f
          items << { "key" => "cost", "label" => text(:cost), "value" => cost.round(4), "text" => ApplicationController.helpers.usd(cost) }
        end
        [ { "items" => items, "by_automation" => by_automation(recent, tz), "title" => text(:by_automation), "empty" => text(:empty) }, [] ]
      end

      # [{name, calls, errors, last_at}] das automações que mais chamaram (as outras origens ficam no total).
      def self.by_automation(scope, _tz)
        rows = scope.where.not(automation_id: nil).group(:automation_id)
                    .pluck(:automation_id, Arel.sql("count(*)"), Arel.sql("count(*) FILTER (WHERE status = 'error')"), Arel.sql("max(created_at)"))
        names = Automation.where(id: rows.map(&:first)).pluck(:id, :name).to_h
        rows.sort_by { |r| -r[1] }.first(TOP).filter_map do |id, n, errors, last|
          names[id] && { "automation_id" => id, "name" => names[id], "calls" => n, "errors" => errors, "last_at" => last&.iso8601 }
        end
      end
    end
  end
end
