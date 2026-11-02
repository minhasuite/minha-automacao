module Automations
  module ActionTypes
    # "Comandar pontos por consulta" (Lote 8, G8; o alvo por área, etiqueta ou
    # `expand` do HA): o mesmo comando em todos os pontos que a consulta do
    # Points::Query acha na hora ("tag=iluminação state=on"). Ponto que só lê
    # ou não aceita o comando fica de fora. Segurada em sombra (comanda aparelho);
    # o "teria feito" lista os pontos.
    class CommandQueryAction < Base
      MAX = 100

      describe key: "command_query", label: "Comandar pontos por consulta", defaults: { "query" => "state=on", "command" => "off" },
               fields: [ f("query", :template, "Consulta (ex.: tag=iluminação state=on)", required: true, en: "Query (e.g. tag=lighting state=on)", es: "Consulta (ej.: tag=iluminación state=on)"),
                         f("command", :select, "Comando", required: true, options: -> { Points::Timeline::COMMAND_LABELS }, en: "Command", es: "Comando"),
                         f("value", :value, "Valor (ajustar/selecionar)", en: "Value (set/select)", es: "Valor (ajustar/seleccionar)") ]
      texts en: { label: "Command points by query" }, es: { label: "Enviar comando a puntos por consulta" }

      def self.rules(node)
        q = node["query"].to_s
        Dsl.template?(q) ? [] : [ Points::Query.error(q) ].compact
      end

      # Pontos que recebem o comando agora (`query`: a consulta já resolvida).
      def self.targets(site, node, query: node["query"].to_s, finder: ->(q) { Points::Query.new(site).call(q) })
        finder.call(query).select { |p| p.writable && Points::Command.commands_for(p).include?(node["command"].to_s) }.first(MAX)
      end

      def self.commanded_point_ids(node, site, _seen)
        Dsl.template?(node["query"]) ? [] : targets(site, node).map(&:id)
      rescue ArgumentError
        []
      end

      def self.shadow_effects(e, node) = list(e, node).map { |p| { "point_id" => p.id, "command" => node["command"], "value" => effect_value(e, node["value"]) }.compact }

      def self.list(e, node) = targets(e.ctx.site, node, query: e.ctx.render(node["query"].to_s), finder: e.ctx.method(:query))

      def self.call(e, _path, node)
        points = list(e, node)
        arg = Dsl.template?(node["value"]) ? e.ctx.render(node["value"]) : node["value"]
        title = "#{Engine::COMMAND_LABELS.fetch(node['command'], node['command'])} por consulta: #{points.size} ponto(s)"
        names = points.map(&:name).join(", ").truncate(400).presence || "nenhum ponto na consulta"
        if e.dry_run?
          points.each { |p| e.ctx.set_value(p, Points::Command.new(p, node["command"].to_s, arg).new_value) }
          return [ title, "simulated", "Não enviado (simulação): #{names}" ]
        end

        failures = points.filter_map do |p|
          c = Points::Command.call(p, node["command"], arg, source: "automation", user: nil, run: e.run)
          "#{p.name}: #{c.error}" if c.status == "failed"
        rescue Points::Command::Error => ex
          "#{p.name}: #{ex.message}"
        end
        [ title, failures.any? ? "error" : "ok", [ names, *failures ].join(" · ").truncate(1000) ]
      rescue ArgumentError => ex
        raise Engine::Failure, ex.message
      end
    end
  end
end
