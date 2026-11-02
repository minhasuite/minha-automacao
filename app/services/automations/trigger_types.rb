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

    PLUGINS = %w[StateTrigger NumericTrigger TimeTrigger SunTrigger CalendarTrigger AlertTrigger ManualTrigger WebhookTrigger NotificationActionTrigger EventTrigger ZoneTrigger PresenceTrigger AlarmTrigger DetectionTrigger].freeze

    # Id do gatilho (Lote 5, `id` do HA): a execução leva em `trigger.id`, e a
    # condição "trigger.id = 'x'" diz qual gatilho disparou.
    TRIGGER_ID = Dsl.f("id", :text, "Id do gatilho (para a condição trigger.id)", en: "Trigger ID (for the trigger.id condition)", es: "ID del disparador (para la condición trigger.id)")

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
               fields: [ f("point", :point, "Ponto", required: true, en: "Point", es: "Punto"), f("from", :value, "De (opcional)", en: "From (optional)", es: "De (opcional)"),
                         f("to", :value, "Para (opcional)", en: "To (optional)", es: "A (opcional)"), f("for", :duration, "Por pelo menos", en: "For at least", es: "Durante al menos"),
                         f("attribute", :text, "Atributo (opcional; vale o atributo em vez do valor)", en: "Attribute (optional; uses the attribute instead of the value)", es: "Atributo (opcional; usa el atributo en lugar del valor)") ]
      texts en: { label: "Point changed", attribute_for: "\"for at least\" can't be used with an attribute." },
            es: { label: "Punto cambió", attribute_for: "\"durante al menos\" no se puede usar con un atributo." },
            "pt-BR" => { attribute_for: "\"por pelo menos\" não vale com atributo." }

      def self.fires_on_change?(t, value, was) = (!t.key?("from") || was == t["from"]) && holds?(t, value)
      def self.holds?(t, value) = !t.key?("to") || value == t["to"]
      # Lote 8: atributo (`points.attrs`) muda pelo Point#report_attrs!, sem carimbo de tempo próprio.
      def self.rules(node) = node["attribute"].present? && node["for"].present? ? [ text(:attribute_for) ] : []
    end

    class NumericTrigger < Base
      describe key: "numeric", label: "Passou de um limite",
               fields: [ f("point", :point, "Ponto", required: true, en: "Point", es: "Punto"), f("above", :number, "Acima de", en: "Above", es: "Por encima de"),
                         f("below", :number, "Abaixo de", en: "Below", es: "Por debajo de"), f("for", :duration, "Por pelo menos", en: "For at least", es: "Durante al menos") ]
      texts en: { label: "Crossed a threshold", range: "enter above and/or below." },
            es: { label: "Cruzó un límite", range: "indica por encima de y/o por debajo de." },
            "pt-BR" => { range: "informe acima de e/ou abaixo de." }

      # Entra na faixa (não repete enquanto continua nela).
      def self.fires_on_change?(t, value, was) = holds?(t, value) && !holds?(t, was)
      def self.holds?(t, v) = v.is_a?(::Numeric) && (t["above"].nil? || v > t["above"]) && (t["below"].nil? || v < t["below"])
      def self.rules(node) = node["above"].nil? && node["below"].nil? ? [ NumericTrigger.text(:range) ] : []
    end

    class TimeTrigger < Base
      # Lote 5: "no horário de um ponto" (`at_point`, o input_datetime do HA):
      # "HH:MM" todo dia ou "AAAA-MM-DDTHH:MM" naquele dia.
      describe key: "time", label: "Horário", defaults: { "at" => "18:00" },
               fields: [ f("at", :time, "Às (HH:MM)", en: "At (HH:MM)", es: "A las (HH:MM)"), f("every", :duration, "Ou a cada (ex.: 10m)", en: "Or every (e.g. 10m)", es: "O cada (ej.: 10m)"),
                         f("at_point", :point, "Ou no horário do ponto (data e hora)", en: "Or at the point's time (date and time)", es: "O a la hora del punto (fecha y hora)"), f("days", :days, "Dias", en: "Days", es: "Días") ]
      texts "pt-BR" => { at: "Horário %{at}", at_point: "Horário do ponto", every: "A cada %{every}",
                         one_of: "use \"às\", \"a cada\" ou \"no horário do ponto\" (só um).", every_range: "\"a cada\" precisa ser de 1 min a 24 h, em minutos inteiros." },
            en: { label: "Time", at: "Time %{at}", at_point: "Point's time", every: "Every %{every}",
                  one_of: "use \"at\", \"every\" or \"at the point's time\" (only one).", every_range: "\"every\" must be from 1 min to 24 h, in whole minutes." },
            es: { label: "Hora", at: "Hora %{at}", at_point: "Hora del punto", every: "Cada %{every}",
                  one_of: "usa \"a las\", \"cada\" o \"a la hora del punto\" (solo uno).", every_range: "\"cada\" debe ser de 1 min a 24 h, en minutos enteros." }
      WHEN = %w[at every at_point].freeze

      def self.clock = true

      def self.title(t)
        return text(:at, at: t["at"]) if t["at"]
        return text(:at_point) if t["at_point"]

        text(:every, every: Dsl.duration_label(Dsl.seconds(t["every"])))
      end

      def self.due?(t, site, local)
        return local.strftime("%H:%M") == t["at"] if t["at"]
        return point_due?(site.points.find_by(id: t["at_point"])&.value.to_s, local) if t["at_point"]

        (((local.hour * 60) + local.min) % (Dsl.seconds(t["every"]) / 60)).zero?
      end

      def self.point_due?(v, local) = v.match?(/\A\d{2}:\d{2}/) ? v[0, 5] == local.strftime("%H:%M") : v[0, 16] == local.strftime("%Y-%m-%dT%H:%M")

      def self.rules(node)
        msgs = []
        msgs << text(:one_of) if WHEN.count { |k| !node[k].nil? } != 1
        sec = node["every"] && Dsl.seconds(node["every"])
        msgs << text(:every_range) if node["every"] && !(sec&.between?(60, 86_400) && (sec % 60).zero?)
        msgs
      end
    end

    class SunTrigger < Base
      describe key: "sun", label: "Sol", defaults: { "event" => "sunset" },
               fields: [ f("event", :select, "Quando", required: true, options: -> { Dsl.sun_events }, en: "When", es: "Cuándo"),
                         f("offset", :duration, "Deslocamento (ex.: -15m)", en: "Offset (e.g. -15m)", es: "Desfase (ej.: -15m)"), f("days", :days, "Dias", en: "Days", es: "Días") ]
      texts en: { label: "Sun" }, es: { label: "Sol" }

      def self.clock = true
      def self.title(t) = Dsl.sun_events[t["event"]]

      def self.due?(t, site, local)
        return false unless site.latitude && site.longitude

        at = Sun.at(t["event"], local.to_date, site.latitude, site.longitude, local.time_zone) or return false
        (at + Dsl.seconds(t["offset"]).to_i).in_time_zone(local.time_zone).strftime("%H:%M") == local.strftime("%H:%M")
      end
    end

    # Disparado pelo AlertRule (Automations::Triggers.alert).
    class AlertTrigger < Base
      describe key: "alert", label: "Alerta", defaults: { "on" => "open" },
               fields: [ f("rule", :alert_rule, "Regra de alerta", required: true, en: "Alert rule", es: "Regla de alerta"),
                         f("on", :select, "Quando", required: true, options: -> { Dsl.alert_events }, en: "When", es: "Cuándo") ]
      texts en: { label: "Alert" }, es: { label: "Alerta" }
    end

    class ManualTrigger < Base
      describe key: "manual", label: "Manual (Executar agora)"
      texts en: { label: "Manual (Run now)" }, es: { label: "Manual (Ejecutar ahora)" }
    end

    class WebhookTrigger < Base
      describe key: "webhook", label: "Webhook (chamada externa com token)"
      texts en: { label: "Webhook (external call with token)" }, es: { label: "Webhook (llamada externa con token)" }
    end
  end
end
