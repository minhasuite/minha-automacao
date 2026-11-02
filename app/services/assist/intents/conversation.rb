module Assist
  module Intents
    # Frases do usuário (ondaB1, B2): as do gatilho "Frase dita ao
    # assistente" das automações, antes das intenções nativas (como no HA).
    # A automação roda com {{ trigger.sentence }} e {{ trigger.slots }}; a
    # resposta é a do gatilho. Papel x risco: o maior risco do que a
    # automação comanda; crítico nunca por voz.
    class Conversation < Intent
      describe key: "conversation", tool: false,
               description: "Frases das automações (gatilho por frase)."
      texts "pt-BR" => { done: "Feito.", denied: "Por voz não posso rodar %{name}." },
            en: { description: "Sentences from automations (sentence trigger).", done: "Done.", denied: "I can't run %{name} by voice." },
            es: { description: "Frases de las automatizaciones (disparador por frase).", done: "Hecho.", denied: "Por voz no puedo ejecutar %{name}." }

      def self.match(ctx, norm)
        a, t, slots = Automations::TriggerTypes::ConversationTrigger.find(ctx.site, norm)
        a && slots.merge("_automation" => a, "_trigger" => t)
      end

      def self.handle(ctx, slots)
        a = slots.delete("_automation")
        t = slots.delete("_trigger")
        risk = a.max_risk(a.definition)
        return reply(text(:denied, name: a.name)) if risk == "critical" || !SiteMembership.allowed?(ctx.role, :command, risk: risk)

        info = { "type" => "conversation", "title" => Automations::TriggerTypes::ConversationTrigger.title(t), "sentence" => ctx.heard, "slots" => slots,
                 "language" => ctx.language, "satellite_id" => ctx.satellite&.id, "user_id" => ctx.user&.id }.compact
        a.fire!(Automations::Triggers.with_id(t, info))
        answer = t["response"].to_s.gsub(/\{(\w+)\}/) { slots[::Regexp.last_match(1)].to_s }.squish
        reply(answer.presence || text(:done))
      end
    end
  end
end
