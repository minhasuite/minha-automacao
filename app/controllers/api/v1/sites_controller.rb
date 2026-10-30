module Api
  module V1
    # Locais (ESQUEMA-V1 §8). Criar: administrador da empresa. Editar e excluir:
    # dono do local. Ver: qualquer papel no local.
    class SitesController < BaseController
      self.key_actions = { index: "read", show: "read" }
      before_action :require_admin!, only: :create
      before_action :set_site, only: %i[show update destroy]

      def index
        records, meta = paginate(visible_sites.order(:name))
        render_data(serialize(records), meta: meta)
      end

      def show
        authorize_site!(@site, :view)
        render_data(serialize(@site))
      end

      def create
        site = Site.create!(params.permit(*SiteSerializer::EDITABLE))
        render_data(serialize(site), status: :created)
      end

      def update
        authorize_site!(@site, :admin)
        @site.update!(params.permit(*SiteSerializer::EDITABLE))
        render_data(serialize(@site))
      end

      def destroy
        authorize_site!(@site, :admin)
        @site.destroy!
        head :no_content
      end

      private

      def set_site = @site = Site.find(params[:id])
      def serialize(obj) = SiteSerializer.new(obj, params: { user: current_user }).to_h
    end
  end
end
