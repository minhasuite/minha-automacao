module Automations
  module TriggerTypes
    # Alarme mudou (Pacote 3): o painel de alarme (helper) entrou num estado
    # (disparado, armando, armado em um modo...). Os estados vêm do registro
    # do painel (HelperTypes::AlarmPanel.states): modo novo aparece aqui sozinho.
    class AlarmTrigger < Base
      describe key: "alarm", label: "Alarme mudou", defaults: { "to" => "triggered" },
               fields: [ f("point", :point, "Painel de alarme", required: true, en: "Alarm panel", es: "Panel de alarma"),
                         f("to", :select, "Para", required: true, options: -> { HelperTypes::AlarmPanel.states }, en: "To", es: "A"),
                         f("from", :select, "De (opcional)", options: -> { HelperTypes::AlarmPanel.states }, en: "From (optional)", es: "De (opcional)") ]
      texts "pt-BR" => { title: "Alarme: %{state}" },
            en: { label: "Alarm changed", title: "Alarm: %{state}" }, es: { label: "La alarma cambió", title: "Alarma: %{state}" }

      def self.fires_on_change?(t, value, was) = value == t["to"] && (t["from"].blank? || was == t["from"])
      def self.title(t) = text(:title, state: HelperTypes::AlarmPanel.states.fetch(t["to"], t["to"]).downcase)
    end
  end
end
