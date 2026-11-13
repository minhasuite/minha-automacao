module Search
  # Cenas: "ativar cena Cinema" (ou só "Cinema") aciona, se o papel deixa.
  class ScenesSource < Source
    def self.prefix = "scene"

    def self.call(q, ctx)
      return [] if q.verb && q.verb != "activate"

      scope(ctx).select { |s| match?(q, s.name) }.first(CANDIDATES).map { |s| build(s, ctx) }
    end

    def self.lookup(id, ctx) = (s = scope(ctx).find_by(id: id)) && build(s, ctx)
    def self.scope(ctx) = Scene.where(site_id: ctx.site_ids, shadow: false).order(:name)

    def self.build(s, ctx)
      risk = s.risk
      allowed = ctx.allowed?(s.site_id, :command, risk: risk)
      action = ({ label: I18n.t("search.activate"), url: activate_scene_path(s), confirm: (I18n.t("search.activate_scene", name: s.name) if risk != "normal"), confirm_title: (Point::RISKS[risk] if risk != "normal") } if allowed)
      Result.new(kind: I18n.t("search.kinds.scene"), title: s.name, subtitle: I18n.t("search.commands_n", n: s.items.size), icon: s.icon.presence || "sparkles",
                 url: edit_scene_path(s), action: action, api: ({ path: "/scenes/#{s.id}/activate", body: {} } if allowed), key: "#{prefix}:#{s.id}")
    end
  end
end
