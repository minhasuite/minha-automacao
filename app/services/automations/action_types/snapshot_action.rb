module Automations
  module ActionTypes
    # Instantâneo (ondaA1, A7; o `scene.create` com `snapshot_entities` do
    # HA): guarda agora o estado dos pontos numa cena "Instantâneo: nome"
    # (categoria Instantâneos, visível e acionável como qualquer cena) e, com
    # "restaurar", volta os pontos para ele. Serve para "piscar a luz e voltar
    # como estava" e para notificação que mexe na TV ou no som.
    class SnapshotAction < Base
      PREFIX = "Instantâneo: ".freeze
      CATEGORY = "Instantâneos".freeze

      describe key: "snapshot", label: "Salvar ou restaurar o estado", defaults: { "mode" => "save" },
               fields: [ f("mode", :select, "Fazer", required: true, options: -> { { "save" => SnapshotAction.text(:save), "restore" => SnapshotAction.text(:restore) } }, en: "Do", es: "Hacer"),
                         f("name", :var, "Nome do instantâneo", required: true, en: "Snapshot name", es: "Nombre de la instantánea"),
                         f("points", :points, "Pontos (salvar)", en: "Points (save)", es: "Puntos (guardar)"),
                         f("query", :template, "Ou consulta (salvar; ex.: area=Sala)", en: "Or query (save; e.g. area=Living)", es: "O consulta (guardar; ej.: area=Sala)") ]
      texts "pt-BR" => { save: "Salvar agora", restore: "Restaurar", none: "escolha os pontos ou a consulta para salvar.", saved: "Salvar estado: %{name}",
                         restored: "Restaurar estado: %{name}", missing: "Instantâneo %{name} não existe (salve antes).", count: "%{n} pontos" },
            en: { label: "Save or restore state", save: "Save now", restore: "Restore", none: "choose the points or the query to save.", saved: "Save state: %{name}",
                  restored: "Restore state: %{name}", missing: "Snapshot %{name} does not exist (save it first).", count: "%{n} points" },
            es: { label: "Guardar o restaurar el estado", save: "Guardar ahora", restore: "Restaurar", none: "elige los puntos o la consulta para guardar.", saved: "Guardar estado: %{name}",
                  restored: "Restaurar estado: %{name}", missing: "La instantánea %{name} no existe (guárdala antes).", count: "%{n} puntos" }

      def self.rules(node) = node["mode"] == "save" && Array(node["points"]).empty? && node["query"].blank? ? [ text(:none) ] : []

      def self.scene_name(node) = "#{PREFIX}#{node['name']}"
      def self.shadow_safe?(_e, node) = node["mode"] == "save" # salvar não mexe em aparelho

      def self.shadow_effects(e, node)
        scene = e.ctx.site.scenes.find_by(name: scene_name(node)) or return []
        scene.items.map { |i| { "point_id" => i["point_id"], "command" => i["command"], "value" => i["value"] }.compact }
      end

      def self.commanded_point_ids(node, site, _seen) = node["mode"] == "restore" ? Array(site.scenes.find_by(name: scene_name(node))&.items).pluck("point_id") : []

      def self.call(e, _path, node)
        node["mode"] == "restore" ? restore(e, node) : save(e, node)
      end

      def self.save(e, node)
        site = e.ctx.site
        ids = Array(node["points"]).filter_map { |ref| e.ctx.point(ref)&.id }
        ids += e.ctx.query(e.ctx.render(node["query"])).map(&:id) if node["query"].present?
        items = site.points.where(id: ids.uniq).filter_map { |p| Scene.capture(p.tap { |x| x.value = e.ctx.value(x) }) }
        title = text(:saved, name: node["name"])
        return [ title, "simulated", text(:count, n: items.size) ] if e.dry_run?

        scene = site.scenes.find_or_initialize_by(name: scene_name(node))
        scene.update!(items: items, category: CATEGORY) if items.any?
        [ title, "ok", text(:count, n: items.size) ]
      end

      def self.restore(e, node)
        scene = e.ctx.site.scenes.find_by(name: scene_name(node)) or raise Engine::Failure, text(:missing, name: node["name"])
        title = text(:restored, name: node["name"])
        return [ title, "simulated", text(:count, n: scene.items.size) ] if e.dry_run?

        commands, failures = scene.activate!(source: "automation", user: nil)
        [ title, failures.any? ? "error" : "ok", [ text(:count, n: commands.size), *failures ].join(" · ") ]
      end
    end
  end
end
