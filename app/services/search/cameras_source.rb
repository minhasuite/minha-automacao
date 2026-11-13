module Search
  # Câmeras (pontos `stream`): abre a página da câmera (ao vivo) na web e a folha do ponto no app.
  class CamerasSource < Source
    def self.prefix = "camera"

    def self.call(q, ctx)
      return [] if q.verb

      areas = PointsSource.areas_for(ctx)
      PointsSource.candidates(ctx).select { |p| p.capability == "stream" && match?(q, p.name, p.device&.name, areas[p.effective_area_id], I18n.t("search.kinds.camera"), "camera") }
                  .first(CANDIDATES).map { |p| build(p, ctx, areas) }
    end

    def self.lookup(id, ctx)
      p = Point.where(site_id: ctx.site_ids, capability: "stream", hidden: false, disabled: false).includes(:device).find_by(id: id) or return nil
      build(p, ctx, PointsSource.areas_for(ctx))
    end

    def self.build(p, ctx, areas)
      r = PointsSource.result(p, Query.parse(""), ctx, areas, kind: I18n.t("search.kinds.camera"), icon: "video-camera", key: prefix)
      r.with(subtitle: [ p.device&.name, areas[p.effective_area_id] ].compact_blank.uniq.join(" · "))
    end
  end
end
