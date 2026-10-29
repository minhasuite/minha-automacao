module Web
  # Locais: lista, um local com suas áreas e o cadastro. Mesmas regras da API.
  class SitesController < ApplicationController
    before_action :require_admin!, only: %i[new create]
    before_action :set_site, only: %i[show edit update destroy]

    def index
      @sites = Site.visible_to(current_user).includes(:areas, :devices).order(:name)
    end

    def show
      authorize_site!(@site, :view)
      @areas = @site.areas.includes(:devices).order(:position, :name)
      @loose_devices = @site.devices.where(area_id: nil).order(:name)
    end

    def new = @site = Site.new

    def create
      @site = Site.new(site_params)
      return render(:new, status: :unprocessable_content) unless @site.save

      redirect_to @site, notice: "Local criado. Agora crie as áreas (cômodos, andares)."
    end

    def edit = authorize_site!(@site, :admin)

    def update
      authorize_site!(@site, :admin)
      return render(:edit, status: :unprocessable_content) unless @site.update(site_params)

      redirect_to @site, notice: "Local atualizado."
    end

    def destroy
      authorize_site!(@site, :admin)
      @site.destroy!
      redirect_to sites_path, notice: "Local excluído."
    end

    private

    def set_site = @site = Site.find(params[:id])
    def site_params = params.require(:site).permit(:name, :kind, :address)

    def require_admin!
      redirect_to sites_path, alert: "Só administrador ou dono da empresa cria locais." unless current_user.admin?
    end
  end
end
