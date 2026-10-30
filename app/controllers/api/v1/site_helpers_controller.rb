module Api
  module V1
    # Helpers do local (F8e): lista só leitura (?type= filtra pelo tipo). Ler e
    # escrever o valor de um helper é pelos pontos (GET /points/:id,
    # POST /points/:id/commands e /points/:id/value), com papel e chave.
    class SiteHelpersController < BaseController
      self.key_actions = { index: "read" }

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        scope = site.points.helpers.ordered
        scope = scope.where(helper: params[:type]) if params[:type].present?
        records, meta = paginate(scope)
        render_data(PointSerializer.new(records).to_h, meta: meta.merge(types: HelperTypes.plugins.map { |p| { key: p.key, title: p.title } }))
      end
    end
  end
end
