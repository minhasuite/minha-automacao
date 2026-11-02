module Search
  # Cenas: "ativar cena Cinema" (ou só "Cinema") aciona, se o papel deixa.
  class ScenesSource < Source
    def self.call(q, ctx)
      return [] if q.verb && q.verb != "activate"

      Scene.where(site_id: ctx.site_ids, shadow: false).order(:name).select { |s| match?(q, s.name) }.first(LIMIT).map do |s|
        risk = s.risk
        action = ({ label: I18n.t("search.activate"), url: activate_scene_path(s), confirm: (I18n.t("search.activate_scene", name: s.name) if risk != "normal"), confirm_title: (Point::RISKS[risk] if risk != "normal") } if ctx.allowed?(s.site_id, :command, risk: risk))
        Result.new(kind: I18n.t("search.kinds.scene"), title: s.name, subtitle: I18n.t("search.commands_n", n: s.items.size), icon: s.icon.presence || "sparkles", url: edit_scene_path(s), action: action)
      end
    end
  end
end
