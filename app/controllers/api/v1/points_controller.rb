module Api
  module V1
    # Pontos do dispositivo e comandos. Cadastro: técnico ou dono. Comando: o
    # papel mínimo depende do risco do ponto (SiteMembership::MIN_ROLE_BY_RISK).
    class PointsController < BaseController
      def index
        device = Device.find(params[:device_id])
        authorize_site!(device.site, :view)
        records, meta = paginate(device.points.ordered)
        render_data(PointSerializer.new(records).to_h, meta: meta)
      end

      def show
        point = Point.find(params[:id])
        authorize_site!(point.site, :view)
        render_data(PointSerializer.new(point).to_h)
      end

      def create
        device = Device.find(params[:device_id])
        authorize_site!(device.site, :manage)
        point = device.points.create!(params.permit(*PointSerializer::EDITABLE).merge(site_id: device.site_id))
        render_data(PointSerializer.new(point).to_h, status: :created)
      end

      def update
        point = Point.find(params[:id])
        authorize_site!(point.site, :manage)
        point.update!(params.permit(*PointSerializer::EDITABLE))
        render_data(PointSerializer.new(point).to_h)
      end

      def destroy
        point = Point.find(params[:id])
        authorize_site!(point.site, :manage)
        point.destroy!
        head :no_content
      end

      # POST /points/:id/commands { command, value? } → o ponto com o valor novo.
      def command
        point = Point.find(params[:id])
        authorize_site!(point.site, :command, risk: point.risk)
        Points::Command.call(point, params.require(:command), params[:value])
        render_data(PointSerializer.new(point).to_h)
      end
    end
  end
end
