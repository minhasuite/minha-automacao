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
          next unless t["point"] == point.id && changed_into?(t, point.value, value_was, repeat: point.capability == "event")

          wait = Dsl.seconds(t["for"]).to_i
          next AutomationTriggerJob.set(wait: wait.seconds).perform_later(a.id, i, point.changed_at.iso8601(6)) if wait.positive?

          Automations.safely { a.fire!(with_id(t, info(t, point, value_was)), cause: cause) }
        end
      end
    end

    # Job do `for`: o ponto ficou no estado o tempo todo (carimbo igual)?
    def fire_after_hold(automation, index, stamp)
      t = automation.definition.dig("triggers", index) or return
      point = automation.site.points.find_by(id: t["point"]) or return
      return unless automation.enabled && point.changed_at&.iso8601(6) == stamp && holds?(t, point.value)

      automation.fire!(with_id(t, info(t, point, nil)))
    end

    # Relógio: gatilhos de horário e de sol que caem neste minuto.
    def tick(now = Time.current)
      types = TriggerTypes.plugins.select(&:clock).map(&:key)
      list = ActsAsTenant.without_tenant do
        Automation.where(enabled: true)
                  .where(([ "definition->'triggers' @> ?" ] * types.size).join(" OR "), *types.map { |k| [ { type: k } ].to_json }).to_a
      end
      list.each do |a|
        ActsAsTenant.with_tenant(a.tenant) do
          a.definition["triggers"].each do |t|
            Automations.safely { a.fire!(with_id(t, clock_info(t, now))) } if clock?(t, a.site, now)
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

    # Eventos do sistema (Lote 4, G6): nome → rótulo. A ação "Disparar evento"
    # não pode usar estes nomes nem os dos plugins de gatilho.
    SYSTEM_EVENTS = { "automation_finished" => "Automação ou script terminou", "notification_action" => "Resposta de aviso",
                      "script_finished" => "Script terminou", "system_started" => "Sistema iniciou" }.freeze

    EVENT_NAME = /\A[a-z0-9][a-z0-9_.:-]{0,59}\z/

    def reserved_event?(name) = SYSTEM_EVENTS.key?(name) || TriggerTypes.plugins.any? { |pl| pl.event == name }

    # Evento interno com nome e dados (Lote 1: "notification_action" quando
    # alguém responde a um aviso, "script_finished" quando um script acaba;
    # Lote 4: "automation_finished" e os da ação "Disparar evento").
    # Dispara as automações com gatilho cujo plugin escuta o evento
    # (`listens?` + `fires_on_event?`, com o nome em `payload["event"]`) e
    # retoma as execuções esperando por ele (espera "event" do motor, com o
    # filtro `match`). `cause`: execução que gerou o evento (laço evitado).
    def event(site_id, name, payload, cause: nil)
      payload = payload.merge("event" => name)
      payload["data"] = payload.except("event") unless payload.key?("data") # "Esperar evento" e {{ trigger.data }} leem daqui
      plugins = TriggerTypes.plugins.select { |pl| pl.listens?(name) }
      if plugins.any?
        Automation.where(site_id: site_id, enabled: true)
                  .where(([ "definition->'triggers' @> ?" ] * plugins.size).join(" OR "), *plugins.map { |pl| [ { type: pl.key } ].to_json }).find_each do |a|
          next if name == "automation_finished" && cause&.automation_id == a.id # o próprio fim não dispara de novo

          t = a.definition["triggers"].find { |tr| (pl = TriggerTypes[tr["type"]]) && pl.listens?(name) && pl.fires_on_event?(tr, payload) } or next
          Automations.safely { a.fire!(with_id(t, TriggerTypes[t["type"]].event_info(t, payload)), cause: cause) }
        end
      end
      AutomationRun.where(site_id: site_id, status: "waiting", dry_run: false)
                   .where("state->'wait'->>'kind' = 'event' AND state->'wait'->>'event' = ?", name)
                   .find_each { |r| Automations.safely { Engine.resume_event(r, payload) } }
    end

    # Lote 5 (G7, `homeassistant: start` do HA): o servidor subiu (o
    # supervisor do Solid Queue, uma vez por início). Cada local recebe o
    # evento "system_started".
    def system_started!
      ActsAsTenant.without_tenant { Site.includes(:tenant).to_a }.each do |site|
        ActsAsTenant.with_tenant(site.tenant) { Automations.safely { event(site.id, "system_started", { "at" => Time.current.iso8601 }) } }
      end
    end

    # Id do gatilho (Lote 5) vai junto: `trigger.id` na condição e no texto.
    def with_id(t, info) = t["id"].present? ? info.merge("id" => t["id"]) : info

    # O plugin do gatilho decide (TriggerTypes).
    # `repeat`: ponto de evento (botão) dispara mesmo com o valor repetido.
    def changed_into?(t, value, was, repeat: false) = (repeat || value != was) && TriggerTypes[t["type"]]&.fires_on_change?(t, value, was) || false
    def holds?(t, value) = TriggerTypes[t["type"]]&.holds?(t, value) || false

    def clock?(t, site, now)
      plugin = TriggerTypes[t["type"]]
      return false unless plugin&.clock

      local = now.in_time_zone(ActiveSupport::TimeZone[site.timezone])
      return false if t["days"] && !t["days"].include?(local.wday)

      plugin.due?(t, site, local)
    end

    # `duration` (Lote 5, G9): segundos que o ponto ficou no valor anterior ("ficou ligado por").
    def info(t, point, was)
      before = point.changed_at_before_last_save if point.saved_change_to_changed_at?
      { "type" => t["type"], "title" => "#{point.name}: #{ApplicationController.helpers.point_value_text(point)}#{" há #{Dsl.duration_label(Dsl.seconds(t['for']))}" if t['for']}",
        "point_id" => point.id, "point" => point.name, "value" => point.value, "from" => was,
        "duration" => ((point.changed_at - before).round if before && point.changed_at) }.compact
    end

    def clock_info(t, now)
      { "type" => t["type"], "title" => TriggerTypes[t["type"]].title(t), "at" => now.iso8601 }
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
