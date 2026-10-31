module Dashboards
  module Widgets
    # Controle remoto (Pacote 1): um botão por código aprendido do ponto
    # `remote` (Broadlink, IR da Tuya ou outro transporte) e, para quem pode
    # comandar, "Aprender botão".
    class RemoteWidget < Base
      describe type: "remote", label: "Controle remoto", icon: "status-online", required: %w[bind], bind: true, auto: %w[remote]

      def self.data(_r, _w, binds)
        point = binds.first
        return [ { "point_ids" => [], "missing" => true }, [] ] unless point&.capability == "remote"

        [ { "point_ids" => [ point.id ], "buttons" => Points::Command.remote_buttons(point), "learn" => Points::Command.commands_for(point).include?("learn") }, [] ]
      end
    end
  end
end
