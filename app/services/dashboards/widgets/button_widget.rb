module Dashboards
  module Widgets
    # Botão (ondaB2 B10; o `button` do HA): ícone grande e nome; o toque faz
    # o `tap_action` ou, sem ele, o natural do ponto (alternar, acionar,
    # rodar). Sem ponto, só os gestos (ir para uma visão, abrir link...).
    class ButtonWidget < Base
      COMMAND = { "command" => "press", "gate" => "pulse", "script" => "run" }.freeze
      describe type: "button", label: "Botão", icon: "cursor-click", params: %w[show_state icon], bind: true
      texts en: { label: "Button" }, es: { label: "Botón" }

      def self.gestures? = true
      def self.form = "web/dashboards/widget_forms/cards"

      def self.data(_r, w, binds)
        p = binds.first
        command = p && (COMMAND[p.capability] || ("toggle" if Points::Command.commands_for(p).include?("toggle")))
        [ { "point_ids" => [ p&.id ].compact, "missing" => p.nil? && w["bind"].present?, "command" => command, "show_state" => w["show_state"] == "1" || (w["show_state"].nil? && !COMMAND.key?(p&.capability)) }.compact, [] ]
      end
    end
  end
end
