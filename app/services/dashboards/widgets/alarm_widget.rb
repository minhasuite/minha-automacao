module Dashboards
  module Widgets
    # Painel de alarme (Pacote 3; o `alarm-panel` do HA): estado, contagem e
    # teclado com o código. Os botões de modo vêm dos comandos do painel
    # (HelperTypes::AlarmPanel::MODES), nada fixo aqui.
    class AlarmWidget < Base
      describe type: "alarm", label: "Painel de alarme", icon: "shield-check", required: %w[bind], bind: true

      def self.data(_r, _w, binds)
        point = binds.first
        return [ { "point_ids" => [], "missing" => true }, [] ] unless point&.helper == "alarm_panel"

        plugin = HelperTypes::AlarmPanel
        modes = plugin.configured(point).map { |s| { "state" => s, "command" => plugin::MODES[s][:command], "label" => plugin::MODES[s][:label] } }
        [ { "point_ids" => [ point.id ], "state" => point.value, "state_text" => plugin.value_text(point), "armed" => plugin.armed?(point.value),
            "modes" => modes, "code_arm" => point.address["code_arm"] == true, "until" => point.address["until"],
            "tripped_by" => point.attrs.to_h["tripped_by"] }, [] ]
      end
    end
  end
end
