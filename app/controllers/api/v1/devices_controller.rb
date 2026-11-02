module Api
  module V1
    # Dispositivos do local (?area_id= filtra). Ver: qualquer papel; cadastro: técnico ou dono.
    class DevicesController < BaseController
      self.key_actions = { index: "read", show: "read" }

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        scope = site.devices.order(:name)
        scope = scope.where(area_id: params[:area_id]) if params[:area_id].present?
        records, meta = paginate(scope)
        render_data(DeviceSerializer.new(records, params: { reveal: reveal_sensitive? }).to_h, meta: meta)
      end

      def show
        device = Device.find(params[:id])
        authorize_site!(device.site, :view)
        render_data(DeviceSerializer.new(device, params: { reveal: reveal_sensitive? }).to_h)
      end

      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        device = site.devices.create!(params.permit(*DeviceSerializer::EDITABLE))
        render_data(DeviceSerializer.new(device, params: { reveal: reveal_sensitive? }).to_h, status: :created)
      end

      def update
        device = Device.find(params[:id])
        authorize_site!(device.site, :manage)
        device.update!(params.permit(*DeviceSerializer::EDITABLE))
        render_data(DeviceSerializer.new(device, params: { reveal: reveal_sensitive? }).to_h)
      end

      def destroy
        device = Device.find(params[:id])
        authorize_site!(device.site, :manage)
        device.destroy!
        head :no_content
      end
    end
  end
end
