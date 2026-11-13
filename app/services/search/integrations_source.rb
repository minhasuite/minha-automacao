module Search
  # Integrações (conta, aparelho da rede, app): para quem cadastra (técnico ou dono).
  class IntegrationsSource < Source
    def self.prefix = "integration"

    def self.call(q, ctx)
      return [] if q.verb

      scope(ctx).select { |i| match?(q, i.name, i.driver_label, "integracao") }.first(CANDIDATES).map { |i| build(i, ctx) }
    end

    def self.lookup(id, ctx) = (i = scope(ctx).find_by(id: id)) && build(i, ctx)
    def self.scope(ctx) = Integration.where(site_id: ctx.site_ids.select { |id| ctx.allowed?(id, :manage) }).order(:name)

    def self.build(i, ctx)
      site = ctx.sites.find { |s| s.id == i.site_id }
      Result.new(kind: I18n.t("search.kinds.integration"), title: i.name, subtitle: [ i.driver_label, (site.name if ctx.sites.size > 1) ].compact.join(" · "),
                 icon: i.icon_name, url: site_integrations_path(i.site_id), key: "#{prefix}:#{i.id}")
    end
  end
end
