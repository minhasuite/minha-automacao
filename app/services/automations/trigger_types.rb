module Automations
  # Gatilhos da DSL como plugins (Block). Tipo novo = classe (aqui ou em
  # automations/trigger_types/<nome>.rb) + nome em PLUGINS; o disparo
  # (Automations::Triggers) só pergunta:
  #   fires_on_change?(t, valor, anterior) — valor novo de ponto (`point`);
  #   holds?(t, valor) — no fim do `for`, ainda vale?
  #   clock + due?(t, site, hora local) + title(t) — relógio, a cada minuto.
  #   event + fires_on_event?(t, dados) + event_info(t, dados) — evento interno
  #     (Triggers.event: resposta de aviso).
  # Gatilho de evento próprio (alerta, webhook, manual) dispara de fora pelo
  # Automation#fire!.
  module TriggerTypes
    extend Block::Registry

    PLUGINS = %w[StateTrigger NumericTrigger TimeTrigger SunTrigger CalendarTrigger AlertTrigger ManualTrigger WebhookTrigger NotificationActionTrigger EventTrigger].freeze

    # Id do gatilho (Lote 5, `id` do HA): a execução leva em `trigger.id`, e a
    # condição "trigger.id = 'x'" diz qual gatilho disparou.
    TRIGGER_ID = Dsl.f("id", :text, "Id do gatilho (para a condição trigger.id)")

    class Base < Block
      class << self
        def fields = super + [ TRIGGER_ID ]
        def fires_on_change?(_t, _value, _was) = false
        def holds?(_t, _value) = true
        def clock = false
        def due?(_t, _site, _local) = false
        def title(_t) = label
        def event = nil
        # Escuta este evento? Padrão: o nome fixo do plugin (`event`).
        def listens?(name) = event.present? && event == name
        def fires_on_event?(_t, _payload) = false
        def event_info(t, _payload) = { "type" => t["type"], "title" => title(t) }
      end
    end

    class StateTrigger < Base
      describe key: "state", label: "Ponto mudou",
               fields: [ f("point", :point, "Ponto", required: true), f("from", :value, "De (opcional)"),
                         f("to", :value, "Para (opcional)"), f("for", :duration, "Por pelo menos"),
                         f("attribute", :text, "Atributo (opcional; vale o atributo em vez do valor)") ]

      def self.fires_on_change?(t, value, was) = (!t.key?("from") || was == t["from"]) && holds?(t, value)
      def self.holds?(t, value) = !t.key?("to") || value == t["to"]
      # Lote 8: atributo (`points.attrs`) muda pelo Point#report_attrs!, sem carimbo de tempo próprio.
      def self.rules(node) = node["attribute"].present? && node["for"].present? ? [ "\"por pelo menos\" não vale com atributo." ] : []
    end

    class NumericTrigger < Base
      describe key: "numeric", label: "Passou de um limite",
               fields: [ f("point", :point, "Ponto", required: true), f("above", :number, "Acima de"),
                         f("below", :number, "Abaixo de"), f("for", :duration, "Por pelo menos") ]

      # Entra na faixa (não repete enquanto continua nela).
      def self.fires_on_change?(t, value, was) = holds?(t, value) && !holds?(t, was)
      def self.holds?(t, v) = v.is_a?(::Numeric) && (t["above"].nil? || v > t["above"]) && (t["below"].nil? || v < t["below"])
      def self.rules(node) = node["above"].nil? && node["below"].nil? ? [ "informe acima de e/ou abaixo de." ] : []
    end

    class TimeTrigger < Base
      # Lote 5: "no horário de um ponto" (`at_point`, o input_datetime do HA):
      # "HH:MM" todo dia ou "AAAA-MM-DDTHH:MM" naquele dia.
      describe key: "time", label: "Horário", defaults: { "at" => "18:00" },
               fields: [ f("at", :time, "Às (HH:MM)"), f("every", :duration, "Ou a cada (ex.: 10m)"),
                         f("at_point", :point, "Ou no horário do ponto (data e hora)"), f("days", :days, "Dias") ]
      WHEN = %w[at every at_point].freeze

      def self.clock = true

      def self.title(t)
        return "Horário #{t['at']}" if t["at"]
        return "Horário do ponto" if t["at_point"]

        "A cada #{Dsl.duration_label(Dsl.seconds(t['every']))}"
      end

      def self.due?(t, site, local)
        return local.strftime("%H:%M") == t["at"] if t["at"]
        return point_due?(site.points.find_by(id: t["at_point"])&.value.to_s, local) if t["at_point"]

        (((local.hour * 60) + local.min) % (Dsl.seconds(t["every"]) / 60)).zero?
      end

      def self.point_due?(v, local) = v.match?(/\A\d{2}:\d{2}/) ? v[0, 5] == local.strftime("%H:%M") : v[0, 16] == local.strftime("%Y-%m-%dT%H:%M")

      def self.rules(node)
        msgs = []
        msgs << "use \"às\", \"a cada\" ou \"no horário do ponto\" (só um)." if WHEN.count { |k| !node[k].nil? } != 1
        sec = node["every"] && Dsl.seconds(node["every"])
        msgs << "\"a cada\" precisa ser de 1 min a 24 h, em minutos inteiros." if node["every"] && !(sec&.between?(60, 86_400) && (sec % 60).zero?)
        msgs
      end
    end

    class SunTrigger < Base
      describe key: "sun", label: "Sol", defaults: { "event" => "sunset" },
               fields: [ f("event", :select, "Quando", required: true, options: Dsl::SUN_EVENTS),
                         f("offset", :duration, "Deslocamento (ex.: -15m)"), f("days", :days, "Dias") ]

      def self.clock = true
      def self.title(t) = Dsl::SUN_EVENTS[t["event"]]

      def self.due?(t, site, local)
        return false unless site.latitude && site.longitude

        at = Sun.at(t["event"], local.to_date, site.latitude, site.longitude, local.time_zone) or return false
        (at + Dsl.seconds(t["offset"]).to_i).in_time_zone(local.time_zone).strftime("%H:%M") == local.strftime("%H:%M")
      end
    end

    # Disparado pelo AlertRule (Automations::Triggers.alert).
    class AlertTrigger < Base
      describe key: "alert", label: "Alerta", defaults: { "on" => "open" },
               fields: [ f("rule", :alert_rule, "Regra de alerta", required: true),
                         f("on", :select, "Quando", required: true, options: Dsl::ALERT_EVENTS) ]
    end

    class ManualTrigger < Base
      describe key: "manual", label: "Manual (Executar agora)"
    end

    class WebhookTrigger < Base
      describe key: "webhook", label: "Webhook (chamada externa com token)"
    end
  end
end
