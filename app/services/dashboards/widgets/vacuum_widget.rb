module Dashboards
  module Widgets
    # Robô (F8): o ponto `vacuum` e os irmãos do mesmo aparelho pelo papel no
    # endereço (situação, bateria, erro, ajustes, peças), cômodos e ações.
    class VacuumWidget < Base
      describe type: "vacuum", label: "Robô aspirador", required: %w[bind], bind: true

      def self.data(r, _w, binds)
        point = binds.first
        return [ { "point_ids" => [], "missing" => true }, [] ] unless point&.capability == "vacuum"

        siblings = r.points.select { |p| p.device_id == point.device_id && p.id != point.id && !p.disabled }.each { |p| r.use(p) }
        by_role = siblings.group_by { |p| p.address["role"] }
        one = ->(role) { by_role[role]&.first&.id }
        [ { "point_ids" => [ point.id ], "rooms" => Array(point.address["rooms"]), "actions" => Array(point.address["actions"]&.keys),
            "detail" => one.call("detail"), "battery" => one.call("battery"), "fault" => one.call("fault"),
            "settings" => Points::Command::VACUUM_SETTINGS.filter_map { |role| (id = one.call(role)) && [ role, id ] }.to_h,
            "parts" => [ *by_role["part"], *by_role["detergent"] ].map(&:id) }, siblings ]
      end

      # Painel automático: largura toda. Não é `auto:` para não trocar o desenho na página do ponto.
      def self.auto_widget(point, id)
        { "id" => id, "type" => type, "bind" => point.id, "span" => { "mobile" => 12, "tablet" => 12, "desktop" => 12 } } if point.capability == "vacuum"
      end
    end
  end
end
