module Web
  # resto (panel_custom do HA): painel lateral de terceiro, instalado por
  # pacote (item `panel`). Roda num iframe sandbox de origem opaca, com o JS
  # conferido pelo hash, e recebe só o estado dos pontos do local (`hass.states`).
  class CustomPanelsController < ApplicationController
    def show
      package = Package.find(params[:package_id])
      authorize_site!(package.site, :view)
      @panel = Cards.panels(Site.where(id: package.site_id)).find { |p| p["package"] == package && p["key"] == params[:key] } or raise ActiveRecord::RecordNotFound

      points = package.site.points.where(disabled: false, hidden: false).order(:name).limit(Cards::MAX_PANEL_POINTS)
      @doc = Cards.srcdoc(@panel.merge("states" => Cards.states(points), "integrity" => Cards.integrity(@panel["sha"])), request.base_url)
    end

    private

    def viewer_allowed? = true
  end
end
