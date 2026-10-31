module Automations
  # Condições da DSL como plugins (Block). Tipo novo = classe (aqui ou em
  # automations/condition_types/<nome>.rb) + nome em PLUGINS, com
  # `check(ev, c)` → [ok, rótulo, valores vistos, filhos]. `ev` é o
  # Automations::Conditions da execução: contexto (`ev.ctx`) e auxiliares
  # (`point!`, `held?`, `window?`, `check` para listas aninhadas).
  module ConditionTypes
    extend Block::Registry

    PLUGINS = %w[StateCondition NumericCondition TimeCondition SunCondition CalendarCondition ZoneCondition AlarmCondition ExprCondition AndCondition OrCondition NotCondition].freeze

    class Base < Block
      def self.check(_ev, _c) = raise(NotImplementedError)
    end

    class StateCondition < Base
      describe key: "state", label: "Ponto está",
               fields: [ f("point", :point, "Ponto", required: true), f("is", :value, "Está"),
                         f("quality", :select, "Ou situação", options: Dsl::QUALITIES), f("for", :duration, "Há pelo menos") ]

      def self.rules(node) = !node.key?("is") && node["quality"].nil? ? [ "informe o valor ou a situação." ] : []

      def self.check(ev, c)
        p = ev.point!(c["point"])
        v = ev.ctx.value(p)
        ok = true
        parts = []
        if c.key?("is")
          ok &&= v == c["is"]
          parts << "está #{ev.label(p, c['is'])}"
        end
        if c["quality"]
          ok &&= p.quality == c["quality"]
          parts << "situação #{Dsl::QUALITIES.fetch(c['quality'], c['quality']).downcase}"
        end
        if c["for"]
          ok = ev.held?(p, c["for"]) && ok
          parts << "há #{Dsl.duration_label(Dsl.seconds(c['for']))}"
        end
        [ ok, "#{p.name} #{parts.join(', ')}", "agora: #{ev.ctx.point_text(p, v)}#{", #{Dsl::QUALITIES[p.quality].downcase}" if p.quality != 'good'}" ]
      end
    end

    class NumericCondition < Base
      describe key: "numeric", label: "Ponto entre limites",
               fields: [ f("point", :point, "Ponto", required: true), f("above", :number, "Acima de"), f("below", :number, "Abaixo de") ]

      def self.rules(node) = TriggerTypes::NumericTrigger.rules(node)

      def self.check(ev, c)
        p = ev.point!(c["point"])
        v = ev.ctx.value(p)
        range = [ ("acima de #{c['above']}" if c["above"]), ("abaixo de #{c['below']}" if c["below"]) ].compact.join(" e ")
        [ TriggerTypes::NumericTrigger.holds?(c, v), "#{p.name} #{range}", "agora: #{ev.ctx.point_text(p, v)}" ]
      end
    end

    class TimeCondition < Base
      describe key: "time", label: "Janela de horário", defaults: { "after" => "18:00" },
               fields: [ f("after", :time, "Depois de"), f("before", :time, "Antes de"), f("days", :days, "Dias") ]

      def self.rules(node) = node["after"].nil? && node["before"].nil? ? [ "informe depois de e/ou antes de." ] : []

      def self.check(ev, c)
        now = ev.ctx.now
        t = now.strftime("%H:%M")
        ok = ev.window?(t, c["after"], c["before"]) && (c["days"].nil? || c["days"].include?(now.wday))
        days = c["days"] && c["days"].size < 7 ? c["days"].map { |d| Dsl::DAYS[d] }.join("/") : nil
        label = [ ("depois de #{c['after']}" if c["after"]), ("antes de #{c['before']}" if c["before"]), days ].compact.join(", ")
        [ ok, "Horário #{label}", "agora: #{t}, #{Dsl::DAYS[now.wday].downcase}" ]
      end
    end

    class SunCondition < Base
      describe key: "sun", label: "Sol", defaults: { "after" => "sunset" },
               fields: [ f("after", :select, "Depois do", options: Dsl::SUN_EVENTS), f("after_offset", :duration, "Deslocamento"),
                         f("before", :select, "Antes do", options: Dsl::SUN_EVENTS), f("before_offset", :duration, "Deslocamento") ]

      def self.rules(node) = TimeCondition.rules(node)

      def self.check(ev, c)
        site = ev.ctx.site
        raise Context::Error, "O local precisa de latitude e longitude." unless site.latitude && site.longitude

        now = ev.ctx.now
        at = ->(e, off) { e && Sun.at(e, now.to_date, site.latitude, site.longitude, now.time_zone)&.+(Dsl.seconds(off).to_i) }
        after = at.call(c["after"], c["after_offset"])
        before = at.call(c["before"], c["before_offset"])
        fmt = ->(x) { x&.in_time_zone(now.time_zone)&.strftime("%H:%M") }
        label = [ ("depois do #{Dsl::SUN_EVENTS[c['after']].downcase} (#{fmt.call(after)})" if c["after"]),
                  ("antes do #{Dsl::SUN_EVENTS[c['before']].downcase} (#{fmt.call(before)})" if c["before"]) ].compact.join(" e ")
        [ ev.window?(now, after, before), "Sol: #{label}", "agora: #{now.strftime('%H:%M')}" ]
      end
    end

    class ExprCondition < Base
      describe key: "expr", label: "Expressão", defaults: { "expr" => "hour >= 18" },
               fields: [ f("expr", :expr, "Expressão (ex.: sala.temperatura > 28 and hour >= 22)", required: true) ]

      def self.check(ev, c)
        r = ev.ctx.calc(c["expr"])
        [ r == true || (r.is_a?(::Numeric) && r.nonzero?), c["expr"], "resultado: #{r.inspect}" ]
      end
    end

    # E / ou / não sobre uma lista (o modo é a própria chave).
    class AndCondition < Base
      describe key: "and", label: "Todas (e)", fields: [ f("conditions", :conditions, "Condições") ]

      def self.word = "Todas"

      def self.check(ev, c)
        ok, children = ev.check(c["conditions"], key)
        [ ok, "#{word} destas", nil, children ]
      end
    end

    class OrCondition < AndCondition
      describe key: "or", label: "Alguma (ou)", fields: [ f("conditions", :conditions, "Condições") ]

      def self.word = "Alguma"
    end

    class NotCondition < AndCondition
      describe key: "not", label: "Nenhuma (não)", fields: [ f("conditions", :conditions, "Condições") ]

      def self.word = "Nenhuma"
    end
  end
end
