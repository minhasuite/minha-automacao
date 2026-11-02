module Api
  module V1
    # Histórico de vários pontos na mesma janela (o da web), para o app:
    # GET /sites/:site_id/history?point_ids[]=…&range=24h (ou from/to).
    # Número → itens {at, avg, min, max}; o resto → trechos {from, to, value, text}.
    class HistoryController < BaseController
      self.key_actions = { index: "read" }

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        ids = Array(params[:point_ids]).compact_blank.uniq.first(Points::Overlay::MAX)
        return render_error(:parameter_missing, "Informe point_ids.", status: :bad_request) if ids.empty?

        zone = ActiveSupport::TimeZone[site.timezone] || Time.zone
        from, to = Time.use_zone(zone) { Points::Overlay.window(params) }
        found = site.points.where(id: ids).index_by(&:id)
        overlay = Points::Overlay.new(ids.filter_map { |id| found[id] }, from: from, to: to)
        render_data(overlay.as_json, meta: { from: from, to: to })
      end
    end
  end
end
