module Web
  # Dispositivo com seus pontos (controle e cadastro).
  class DevicesController < ApplicationController
    def show
      load_for(:view)
      @points = @device.points.ordered
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @device = @site.devices.new(area_id: params[:area_id].presence)
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @device = @site.devices.new(device_params)
      return render(:new, status: :unprocessable_content) unless @device.save

      redirect_to @device, notice: "Dispositivo criado. Adicione os pontos dele."
    end

    def edit = load_for(:manage)

    def update
      load_for(:manage)
      return render(:edit, status: :unprocessable_content) unless @device.update(device_params)

      redirect_to @device, notice: "Dispositivo atualizado."
    end

    def destroy
      load_for(:manage)
      @device.destroy!
      redirect_to(@device.area || @site, notice: "Dispositivo excluído.")
    end

    private

    def load_for(action)
      @device = Device.find(params[:id])
      @site = @device.site
      authorize_site!(@site, action)
    end

    def device_params = params.require(:device).permit(:name, :area_id, :driver, :manufacturer, :model, :serial, :disabled, :listen)
  end
end
