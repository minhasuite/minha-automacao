module Search
  class AreasSource < Source
    def self.prefix = "area"

    def self.call(q, ctx)
      return [] if q.verb

      scope(ctx).select { |a| match?(q, *a.all_names) }.first(CANDIDATES).map { |a| build(a) }
    end

    def self.lookup(id, ctx) = (a = scope(ctx).find_by(id: id)) && build(a)
    def self.scope(ctx) = Area.where(site_id: ctx.site_ids).order(:position, :name)

    def self.build(a)
      Result.new(kind: I18n.t("search.kinds.area"), title: a.name, subtitle: a.kind_label, icon: a.icon.presence || "home", url: area_path(a), key: "#{prefix}:#{a.id}")
    end
  end
end
