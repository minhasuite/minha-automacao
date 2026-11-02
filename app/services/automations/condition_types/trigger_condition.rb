module Automations
  module ConditionTypes
    # "Disparado por" (ondaA1, A5; a condição `trigger` do HA): o id do
    # gatilho que disparou é um destes.
    class TriggerCondition < Base
      describe key: "trigger", label: "Disparado pelo gatilho",
               fields: [ f("ids", :text, "Ids dos gatilhos (separados por vírgula)", required: true, en: "Trigger ids (comma separated)", es: "Ids de los disparadores (separados por coma)") ]
      texts en: { label: "Triggered by" }, es: { label: "Disparado por" }

      def self.ids(c) = c["ids"].to_s.split(",").map(&:strip).compact_blank

      def self.check(ev, c)
        got = ev.ctx.trigger["id"].to_s
        [ ids(c).include?(got), "#{label}: #{ids(c).join(', ')}", got.presence || "—" ]
      end
    end
  end
end
