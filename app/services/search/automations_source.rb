module Search
  # Automações: só para quem edita (técnico ou dono). Scripts têm fonte própria.
  class AutomationsSource < Source
    def self.prefix = "automation"

    def self.call(q, ctx)
      return [] if q.verb

      scope(ctx).select { |a| match?(q, a.name, a.description, "automacao") }.first(CANDIDATES).map { |a| build(a) }
    end

    def self.lookup(id, ctx) = (a = scope(ctx).find_by(id: id)) && build(a)
    def self.scope(ctx) = Automation.where(kind: "automation", site_id: ctx.site_ids.select { |id| ctx.allowed?(id, :manage) }).order(:name)

    def self.build(a)
      Result.new(kind: I18n.t("search.kinds.automation"), title: a.name, subtitle: I18n.t(a.enabled ? "search.on" : "search.off"), icon: "switch-horizontal",
                 url: edit_automation_path(a), key: "#{prefix}:#{a.id}")
    end
  end
end
