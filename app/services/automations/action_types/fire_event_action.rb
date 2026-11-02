module Automations
  module ActionTypes
    # "Disparar evento" (Lote 4, G6; `event:` do HA): nome e dados (cada valor
    # é um texto Liquid). Acorda o gatilho "Evento" e quem espera com "Esperar
    # evento" no mesmo local. Nomes do sistema ficam reservados.
    class FireEventAction < Base
      # Evento interno: quem dispara junto herda a sombra (`cause`).
      def self.shadow_safe?(_e, _node) = true

      describe key: "fire_event", label: "Disparar evento",
               fields: [ f("event", :text, "Nome do evento", required: true, en: "Event name", es: "Nombre del evento"),
                         f("data", :kv, "Dados (um por linha, campo: texto com {{ }})", en: "Data (one per line, field: text with {{ }})", es: "Datos (uno por línea, campo: texto con {{ }})") ]
      texts "pt-BR" => { name: "nome do evento: letras minúsculas, números, _ . : e - (até 60).", reserved: "\"%{name}\" é um evento do sistema." },
            en: { label: "Fire event", name: "event name: lowercase letters, numbers, _ . : and - (up to 60).", reserved: "\"%{name}\" is a system event." },
            es: { label: "Disparar evento", name: "nombre del evento: letras minúsculas, números, _ . : y - (hasta 60).", reserved: "\"%{name}\" es un evento del sistema." }

      def self.rules(node)
        name = node["event"]
        return [ text(:name) ] unless name.is_a?(String) && name.match?(Triggers::EVENT_NAME)

        Triggers.reserved_event?(name) ? [ text(:reserved, name: name) ] : []
      end

      def self.call(e, _path, node)
        data = node["data"].to_h.transform_values { |v| e.ctx.render(v) }
        title = "Disparar evento #{node['event']}"
        return [ title, "simulated", "Não disparado (simulação)#{": #{data.keys.join(', ')}" if data.any?}" ] if e.dry_run?

        # Dados no topo (filtro do gatilho e da espera) e inteiros em "data"; "error" só em "data".
        Triggers.event(e.run.site_id, node["event"], data.except("error", "event").merge("data" => data), cause: e.run)
        [ title, "ok", data.keys.join(", ").presence ]
      end
    end
  end
end
