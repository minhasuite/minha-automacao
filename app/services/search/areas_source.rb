module Search
  class AreasSource < Source
    def self.call(q, ctx)
      return [] if q.verb

      Area.where(site_id: ctx.site_ids).order(:position, :name).select { |a| match?(q, a.name) }.first(LIMIT)
          .map { |a| Result.new(kind: "Área", title: a.name, subtitle: a.kind_label, icon: a.icon.presence || "home", url: area_path(a)) }
    end
  end
end
