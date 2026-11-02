module Api
  module V1
    # Diário do local (o mesmo da web): GET /sites/:site_id/logbook com os
    # filtros `period`, `from`, `until`, `area_id`, `device_id`, `point_id`,
    # `user_id`, `q`, `sources[]` e o cursor `before` (meta.next_before).
    # Qualquer papel (cadastro e entradas só para quem pode); chave com read.
    class LogbookController < BaseController
      self.key_actions = { index: "read" }

      def index
        site = Site.find(params[:site_id])
        role = authorize_site!(site, :view)
        filter = Logbook::Filter.new(site: site, role: role, limit: params[:limit].to_i.clamp(1, 200).nonzero? || Logbook::PAGE,
                                     params: params.permit(:period, :from, :until, :area_id, :device_id, :point_id, :user_id, :q, :before, sources: []))
        items, cursor = Logbook.call(filter)
        render_data(items.as_json, meta: { next_before: cursor, from: filter.from, sources: Logbook.sources_for(role).map { |s| { key: s.key, label: s.label } } })
      end
    end
  end
end
