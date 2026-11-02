module Automations
  module TriggerTypes
    # Template (ondaA1, A5; o gatilho `template` do HA): dispara quando a
    # expressão passa de falsa para verdadeira (e não de novo enquanto
    # continua verdadeira). Reavaliada a cada valor novo de ponto do local e
    # a cada minuto (hora na expressão); o último resultado fica em
    # `automations.trigger_state`.
    class TemplateTrigger < Base
      describe key: "template", label: "Expressão ficou verdadeira",
               fields: [ f("expr", :expr, "Expressão (ex.: sala.temperatura > 28)", required: true, en: "Expression (e.g. room.temperature > 28)", es: "Expresión (ej.: sala.temperatura > 28)") ]
      texts en: { label: "Expression became true" }, es: { label: "La expresión se volvió verdadera" }

      def self.reevaluate? = true

      def self.true_now?(t, ctx)
        ctx.calc(t["expr"].to_s) ? true : false
      rescue Context::Error
        false
      end

      def self.title(t) = "#{label}: #{t['expr'].to_s.truncate(60)}"
    end
  end
end
