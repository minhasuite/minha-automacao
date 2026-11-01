module Dashboards
  module Widgets
    # Grupo de pontos (F5): lista com interruptor; `missing` = algum ponto sumiu.
    class GroupWidget < Base
      describe type: "group", label: "Grupo de pontos", icon: "view-list", required: %w[binds], binds: true

      def self.data(_r, w, binds) = [ { "point_ids" => binds.map(&:id), "missing" => binds.size < [ w["bind"], *Array(w["binds"]) ].compact.size }, [] ]
    end
  end
end
