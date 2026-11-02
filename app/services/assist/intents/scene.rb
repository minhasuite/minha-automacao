module Assist
  module Intents
    # Cena ou script pelo nome ("ativar a cena cinema", "executar o script
    # chegada"; o "turn on <cena>" do HA também cai aqui, depois do liga/desliga).
    class Scene < Intent
      describe key: "scene", slots: %w[name],
               description: "Aciona uma cena ou executa um script do local.",
               sentences: { "pt-BR" => [ "(ativar|ative|ativa|acionar|acione|aciona|executar|execute|executa|rodar|rode|roda|ligar|ligue|liga) [a|o] [cena|script|rotina|modo] {name}" ],
                            "en" => [ "(activate|run|start|turn on|execute) [the] [scene|script|routine|mode] {name}", "[set] {name} (scene|mode)" ],
                            "es" => [ "(activa|activar|ejecuta|ejecutar|enciende|pon) [la|el] [escena|script|rutina|modo] {name}" ] }
      texts "pt-BR" => { done: "Cena %{name} acionada.", failed: "Cena %{name} com falhas: %{failures}.", denied: "Por voz não posso acionar a cena %{name}.",
                         script: "Script %{name} executado." },
            en: { description: "Activates a scene or runs a script of the site.", done: "Scene %{name} activated.", failed: "Scene %{name} had failures: %{failures}.",
                  denied: "I can't activate the scene %{name} by voice.", script: "Script %{name} started." },
            es: { description: "Activa una escena o ejecuta un script del lugar.", done: "Escena %{name} activada.", failed: "Escena %{name} con fallas: %{failures}.",
                  denied: "Por voz no puedo activar la escena %{name}.", script: "Script %{name} ejecutado." }

      def self.handle(ctx, slots)
        want = Assist.clean(slots["name"])
        scene = ctx.site.scenes.to_a.find { |s| [ s.name, s.alexa_name ].compact.any? { |n| Assist.clean(n) == want } }
        return script(ctx, slots) unless scene
        return reply(text(:denied, name: scene.name)) unless scene.risk != "critical" && SiteMembership.allowed?(ctx.role, :command, risk: scene.risk)

        _commands, failures = scene.activate!(source: "voice", user: ctx.user)
        reply(failures.any? ? text(:failed, name: scene.name, failures: failures.to_sentence) : text(:done, name: scene.name))
      end

      def self.script(ctx, slots)
        points = Assist.find_points(ctx.site, slots["name"]).select { |p| p.capability == "script" }.first(1)
        run(ctx, points, "run", done: :script, name: points.first&.name)
      end
    end
  end
end
