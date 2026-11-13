module Automations
  module ConditionTypes
    # Pessoa na zona ("se a Kadidja estiver em casa"): o ponto é a pessoa
    # (helper Pessoa, valor = nome da zona) e `zone` o helper Zona. "Ninguém
    # em casa" continua sendo a condição "Alguém na zona" sobre a zona.
    class PersonCondition < Base
      describe key: "person", label: "Pessoa na zona", defaults: { "state" => "in" },
               fields: [ f("point", :point, "Pessoa", required: true, en: "Person", es: "Persona"), f("zone", :point, "Zona", required: true, en: "Zone", es: "Zona"),
                         f("state", :select, "Situação", required: true, options: -> { states }, en: "Status", es: "Situación") ]
      texts "pt-BR" => { states: { in: "Está na zona", out: "Não está na zona" }, now: "agora: %{zone}" },
            en: { label: "Person in zone", states: { in: "Is in the zone", out: "Is not in the zone" }, now: "now: %{zone}" },
            es: { label: "Persona en la zona", states: { in: "Está en la zona", out: "No está en la zona" }, now: "ahora: %{zone}" }

      def self.states = %w[in out].index_with { |k| text("states.#{k}") }

      def self.check(ev, c)
        person = ev.point!(c["point"])
        zone = ev.point!(c["zone"])
        now = ev.ctx.value(person).to_s
        inside = now == zone.name
        [ c["state"] == "out" ? !inside : inside, "#{person.name}: #{states.fetch(c['state'], '')} (#{zone.name})", text(:now, zone: now.presence || "—") ]
      end
    end
  end
end
