module Assist
  module Intents
    # Intenções personalizadas (P3): as frases que o dono cadastrou por local
    # e idioma (`AssistCustomIntent`) acionam a cena ou rodam o script
    # escolhido, depois das frases das automações e antes das nativas. Mesma
    # regra da voz: papel x risco de quem fala, crítico nunca, sombra do local
    # (`Shadow.for_site`). A resposta é a do registro (`{slot}` trocado) ou a
    # padrão.
    class Custom < Intent
      describe key: "custom", tool: false,
               description: "Frases da casa que acionam uma cena ou um script."
      texts "pt-BR" => { done: "Feito: %{name}.", denied: "Por voz não posso acionar %{name}.", failed: "%{name} com falhas: %{failures}." },
            en: { description: "House sentences that activate a scene or run a script.", done: "Done: %{name}.", denied: "I can't run %{name} by voice.",
                  failed: "%{name} had failures: %{failures}." },
            es: { description: "Frases de la casa que activan una escena o ejecutan un script.", done: "Hecho: %{name}.", denied: "Por voz no puedo activar %{name}.",
                  failed: "%{name} con fallas: %{failures}." }

      def self.match(ctx, norm)
        AssistCustomIntent.enabled.where(site_id: ctx.site.id).includes(:scene, :point).order(:name).each do |c|
          slots = c.match(norm, ctx.language) and return slots.merge("_custom" => c)
        end
        nil
      end

      def self.handle(ctx, slots)
        custom = slots.delete("_custom")
        name = custom.target_name or return nil
        return reply(text(:denied, name: name)) unless allowed?(ctx, custom.risk)

        failures = Shadow.for_site(ctx.site) { custom.scene ? scene!(ctx, custom.scene) : script!(ctx, custom.point) }
        return reply(text(:failed, name: name, failures: failures.to_sentence)) if failures.any?

        reply(custom.answer(slots).presence || text(:done, name: name), points: [ custom.point ].compact)
      end

      def self.allowed?(ctx, risk) = risk != "critical" && SiteMembership.allowed?(ctx.role, :command, risk: risk)

      def self.scene!(ctx, scene) = scene.activate!(source: "voice", user: ctx.user).last

      def self.script!(ctx, point)
        c = Points::Command.call(point, "run", nil, source: "voice", user: ctx.user)
        c.error ? [ c.error ] : []
      rescue Points::Command::Error => e
        [ e.message ]
      end
    end
  end
end
