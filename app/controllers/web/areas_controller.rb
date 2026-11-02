module Web
  # Área com seus dispositivos e o controle dos pontos.
  class AreasController < ApplicationController
    def show
      @area = Area.find(params[:id])
      @site = @area.site
      authorize_site!(@site, :view)
      @devices = @area.devices.includes(:points).order(:name)
      @children = @site.areas.where(parent_id: @area.id).order(:level, :position, :name)
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @area = @site.areas.new(kind: params[:kind].presence_in(Area::KINDS.keys) || "room", parent_id: params[:parent_id])
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @area = @site.areas.new(area_params)
      return render(:new, status: :unprocessable_content) unless @area.save

      redirect_to @area, notice: t("notices.area_created")
    end

    def edit = load_for(:manage)

    def update
      load_for(:manage)
      return render(:edit, status: :unprocessable_content) unless @area.update(area_params)

      redirect_to @area, notice: t("notices.area_updated")
    end

    def destroy
      load_for(:manage)
      @area.destroy!
      redirect_to @site, notice: t("notices.area_deleted")
    end

    private

    def load_for(action)
      @area = Area.find(params[:id])
      @site = @area.site
      authorize_site!(@site, action)
    end

    def area_params = params.require(:area).permit(:name, :kind, :parent_id, :level)
  end
end
