module Dashboards
  module Widgets
    # Cartão da área (F5): ligados, abertos, movimento, potência e sem sinal;
    # navega para a view com `area` igual.
    class AreaCardWidget < Base
      describe type: "area_card", label: "Área", icon: "home", required: %w[area], params: %w[area]
      texts en: { label: "Area" },
            es: { label: "Área" }

      def self.data(r, w, _binds)
        area = r.site.areas.find_by(id: w["area"])
        return [ { "missing" => true }, [] ] unless area

        inside = r.points.select { |p| p.effective_area_id == area.id && !p.hidden }
        power = inside.select { |p| p.capability == "measure" && (p.device_class == "power" || p.unit == "W") }.map(&:value).grep(Numeric)
        view = Array(r.definition["views"]).find { |v| v["area"] == area.id }
        [ { "area" => { "id" => area.id, "name" => area.name, "icon" => area.icon, "background" => area.background },
            "view_id" => view&.dig("id"),
            "on" => inside.count { |p| p.capability == "onoff" && p.value == true },
            "open" => inside.count { |p| p.capability.in?(%w[contact gate]) && (p.value == true || p.value == "open") },
            "motion" => inside.any? { |p| p.capability == "motion" && p.value == true },
            "power" => power.any? ? power.sum.round(1) : nil,
            "unavailable" => inside.count { |p| p.quality != "good" },
            "total" => inside.size }, inside ]
      end

      def self.form = "web/dashboards/widget_forms/area_card"
    end
  end
end
