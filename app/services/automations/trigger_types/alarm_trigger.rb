module Automations
  module TriggerTypes
    # Alarme mudou (Pacote 3): o painel de alarme (helper) entrou num estado
    # (disparado, armando, armado em um modo...). Os estados vêm do registro
    # do painel (HelperTypes::AlarmPanel.states): modo novo aparece aqui sozinho.
    class AlarmTrigger < Base
      describe key: "alarm", label: "Alarme mudou", defaults: { "to" => "triggered" },
               fields: [ f("point", :point, "Painel de alarme", required: true),
                         f("to", :select, "Para", required: true, options: -> { HelperTypes::AlarmPanel.states }),
                         f("from", :select, "De (opcional)", options: -> { HelperTypes::AlarmPanel.states }) ]

      def self.fires_on_change?(t, value, was) = value == t["to"] && (t["from"].blank? || was == t["from"])
      def self.title(t) = "Alarme: #{HelperTypes::AlarmPanel.states.fetch(t['to'], t['to']).downcase}"
    end
  end
end
