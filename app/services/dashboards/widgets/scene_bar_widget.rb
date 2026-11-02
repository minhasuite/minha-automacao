module Dashboards
  module Widgets
    # Cenas (F5): botões das cenas marcadas (nenhuma = todas).
    class SceneBarWidget < Base
      describe type: "scene_bar", label: "Cenas", icon: "sparkles"
      texts en: { label: "Scenes" },
            es: { label: "Escenas" }

      def self.data(r, w, _binds)
        list = r.site.scenes.order(:name)
        list = list.where(id: w["scenes"]) if w["scenes"].present?
        scenes = list.map do |s|
          risk = s.risk
          { "id" => s.id, "name" => s.name, "icon" => s.icon, "confirm" => risk != "normal", "can_activate" => SiteMembership.allowed?(r.role, :command, risk: risk) }
        end
        [ { "scenes" => scenes }, [] ]
      end

      def self.permit = [ { "scenes" => [] } ]
      def self.attrs(p, _site = nil) = { "scenes" => Array(p[:scenes]).compact_blank.presence }
      def self.form = "web/dashboards/widget_forms/scene_bar"
    end
  end
end
