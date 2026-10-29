module Api
  module V1
    # Áreas do local. Ver: qualquer papel; criar, editar, excluir: técnico ou dono.
    class AreasController < BaseController
      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        records, meta = paginate(site.areas.order(:position, :name))
        render_data(AreaSerializer.new(records).to_h, meta: meta)
      end

      def show
        area = Area.find(params[:id])
        authorize_site!(area.site, :view)
        render_data(AreaSerializer.new(area).to_h)
      end

      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        area = site.areas.create!(params.permit(*AreaSerializer::EDITABLE))
        render_data(AreaSerializer.new(area).to_h, status: :created)
      end

      def update
        area = Area.find(params[:id])
        authorize_site!(area.site, :manage)
        area.update!(params.permit(*AreaSerializer::EDITABLE))
        render_data(AreaSerializer.new(area).to_h)
      end

      def destroy
        area = Area.find(params[:id])
        authorize_site!(area.site, :manage)
        area.destroy!
        head :no_content
      end
    end
  end
end
