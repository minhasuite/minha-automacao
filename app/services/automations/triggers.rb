module Automations
  # De onde as automações disparam: valor novo de ponto (`on_change`, pelo
  # `Point#report!`), o relógio (`tick`, a cada minuto pelo RunSchedulesJob),
  # alerta aberto/ciente/fechado (`alert`), webhook e "executar agora" (no
  # Automation#fire!). Gatilho com `for` agenda o AutomationTriggerJob com o
  # carimbo `changed_at`: se o ponto mudou de novo, o job velho não dispara.
  module Triggers
    module_function

    # `fresh` falso = valor que voltou com a conexão: não dispara nada (como
    # as primitivas da F4), mas as esperas por condição olham de novo.
    def on_change(point, value_was, fresh: true)
      fire_point_triggers(point, value_was) if fresh
      AutomationRun.where(site_id: point.site_id, status: "waiting", dry_run: false)
                   .where("state->'wait'->>'kind' = 'wait_for'").find_each { |r| Automations.safely { Engine.resume(r) } }
    end

    def fire_point_triggers(point, value_was)
      cause = cause_of(point)
      Automation.where(site_id: point.site_id, enabled: true).where("definition->'triggers' @> ?", [ { point: point.id } ].to_json).find_each do |a|
        a.definition["triggers"].each_with_index do |t, i|
          next unless t["point"] == point.id && changed_into?(t, point.value, value_was)

          wait = Dsl.seconds(t["for"]).to_i
          next AutomationTriggerJob.set(wait: wait.seconds).perform_later(a.id, i, point.changed_at.iso8601(6)) if wait.positive?

          Automations.safely { a.fire!(info(t, point, value_was), cause: cause) }
        end
      end
    end

    # Job do `for`: o ponto ficou no estado o tempo todo (carimbo igual)?
    def fire_after_hold(automation, index, stamp)
      t = automation.definition.dig("triggers", index) or return
      point = automation.site.points.find_by(id: t["point"]) or return
      return unless automation.enabled && point.changed_at&.iso8601(6) == stamp && holds?(t, point.value)

      automation.fire!(info(t, point, nil))
    end

    # Relógio: gatilhos de horário e de sol que caem neste minuto.
    def tick(now = Time.current)
      list = ActsAsTenant.without_tenant do
        Automation.where(enabled: true)
                  .where("definition->'triggers' @> ? OR definition->'triggers' @> ?", [ { type: "time" } ].to_json, [ { type: "sun" } ].to_json).to_a
      end
      list.each do |a|
        ActsAsTenant.with_tenant(a.tenant) do
          a.definition["triggers"].each do |t|
            Automations.safely { a.fire!(clock_info(t, now)) } if clock?(t, a.site, now)
          end
        end
      end
    end

    def alert(alert, event)
      Automation.where(site_id: alert.site_id, enabled: true)
                .where("definition->'triggers' @> ?", [ { type: "alert", rule: alert.alert_rule_id } ].to_json).find_each do |a|
        next unless a.definition["triggers"].any? { |t| t["type"] == "alert" && t["rule"] == alert.alert_rule_id && t["on"] == event }

        Automations.safely do
          a.fire!({ "type" => "alert", "title" => "Alerta #{alert.alert_rule.name}: #{Dsl::ALERT_EVENTS[event].downcase}",
                    "alert_id" => alert.id, "event" => event, "point" => alert.point.name, "value" => alert.point.value })
        end
      end
    end

    def changed_into?(t, value, was)
      return false if value == was

      case t["type"]
      when "state" then (!t.key?("from") || was == t["from"]) && (!t.key?("to") || value == t["to"])
      when "numeric" then in_range?(t, value) && !in_range?(t, was)
      else false
      end
    end

    def holds?(t, value)
      t["type"] == "numeric" ? in_range?(t, value) : (!t.key?("to") || value == t["to"])
    end

    def in_range?(t, v) = v.is_a?(Numeric) && (t["above"].nil? || v > t["above"]) && (t["below"].nil? || v < t["below"])

    def clock?(t, site, now)
      zone = ActiveSupport::TimeZone[site.timezone]
      local = now.in_time_zone(zone)
      return false if t["days"] && !t["days"].include?(local.wday)

      case t["type"]
      when "time"
        minute_of_day = (local.hour * 60) + local.min
        t["at"] ? local.strftime("%H:%M") == t["at"] : (minute_of_day % (Dsl.seconds(t["every"]) / 60)).zero?
      when "sun"
        return false unless site.latitude && site.longitude

        at = Sun.at(t["event"], local.to_date, site.latitude, site.longitude, zone) or return false
        (at + Dsl.seconds(t["offset"]).to_i).in_time_zone(zone).strftime("%H:%M") == local.strftime("%H:%M")
      else false
      end
    end

    def info(t, point, was)
      { "type" => t["type"], "title" => "#{point.name}: #{ApplicationController.helpers.point_value_text(point)}#{" há #{Dsl.duration_label(Dsl.seconds(t['for']))}" if t['for']}",
        "point_id" => point.id, "point" => point.name, "value" => point.value, "from" => was }.compact
    end

    def clock_info(t, now)
      title = t["type"] == "time" ? (t["at"] ? "Horário #{t['at']}" : "A cada #{Dsl.duration_label(Dsl.seconds(t['every']))}") : Dsl::SUN_EVENTS[t["event"]]
      { "type" => t["type"], "title" => title, "at" => now.iso8601 }
    end

    # Quem causou a mudança: a execução rodando nesta thread (pontos virtuais
    # em cadeia) ou um comando recente de automação no ponto (aparelho de
    # verdade confirma depois, em outro job).
    def cause_of(point)
      Thread.current[:automation_run] ||
        Command.where(point_id: point.id, created_at: Automation::CAUSE_WINDOW.ago..).where.not(automation_run_id: nil)
               .order(created_at: :desc).first&.then { |c| AutomationRun.find_by(id: c.automation_run_id) }
    end
  end
end
