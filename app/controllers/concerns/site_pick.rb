# Telas da instalação que olham um local por vez (Diário, Histórico, Mapa):
# o local do parâmetro, senão o do Início da pessoa, senão o primeiro.
module SitePick
  extend ActiveSupport::Concern

  private

  # → o local (com o papel em @site_role) ou nil quando a pessoa não tem nenhum.
  def pick_site(action = :view)
    @sites = Site.visible_to(current_user).order(:name).to_a
    @site = @sites.find { |s| s.id == params[:site_id] } || @sites.find { |s| s.id == current_user.dashboard_prefs["site"] } || @sites.first
    authorize_site!(@site, action) if @site
    @site
  end
end
