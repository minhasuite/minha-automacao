module Api
  module V1
    # Alertas de detecção para o app (app3): as detecções das câmeras com IA do
    # local (capacidade `detection`, de qualquer plugin: Frigate, Reolink,
    # UniFi…), da mais nova para a mais velha.
    # GET /sites/:site_id/detections?kind=person&point_id=&before=<ISO>&limit=50
    # `snapshot_path` (relativo a /api/v1): o quadro do evento quando o plugin
    # guarda por evento (`event_snapshots?`), senão só o da detecção de agora.
    class DetectionsController < BaseController
      self.key_actions = { index: "read" }
      EVENT_ID = /\A[\w.:-]{1,80}\z/
      PAGE = 50

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        points = site.points.where(capability: "detection", hidden: false).includes(:device).index_by(&:id)
        points = points.slice(params[:point_id]) if params[:point_id].present?
        limit = (params[:limit].presence || PAGE).to_i.clamp(1, 100)
        rows = Reading.where(point_id: points.keys).where.not(value_text: nil).order(at: :desc).limit(limit)
        rows = rows.where(at: ...Time.iso8601(params[:before].to_s)) if params[:before].present?
        if (kind = params[:kind].presence_in(Detections::KINDS.keys))
          rows = rows.where("CASE WHEN value_text LIKE '{%' THEN value_text::jsonb ->> 'kind' END = ?", kind)
        end
        items = rows.filter_map { |r| item(points[r.point_id], r) }
        render_data(items, meta: { next_before: (rows.last.at.utc.iso8601(6) if rows.size == limit),
                                   kinds: Detections::KINDS.map { |k, l| { key: k, label: l } } })
      rescue ArgumentError
        render_error(:invalid_parameter, "before precisa ser uma data ISO 8601.", status: :bad_request)
      end

      private

      def item(point, reading)
        v = JSON.parse(reading.value_text)
        return unless v.is_a?(Hash)

        { id: "#{point.id}-#{reading.at.to_f}", point_id: point.id, camera: point.device&.name || point.name,
          kind: v["kind"], kind_label: Detections::KINDS[v["kind"]], label: v["label"], score: v["score"], zones: v["zones"],
          text: Detections.text(v), event_id: v["id"], clip: v["clip"], at: reading.at.iso8601(3), snapshot_path: snapshot_path(point, reading, v) }.compact
      rescue JSON::ParserError
        nil
      end

      def snapshot_path(point, reading, v)
        base = "/points/#{point.id}/snapshot"
        return "#{base}?event=#{CGI.escape(v['id'])}" if v["id"].to_s.match?(EVENT_ID) && Integrations.for_driver(point.device&.driver)&.event_snapshots?

        base if point.changed_at && (reading.at - point.changed_at).abs < 0.001
      end
    end
  end
end
