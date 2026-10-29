module Web
  class DashboardController < ApplicationController
    # Início: o painel padrão da pessoa no local dela (o escolhido em "Abrir no
    # Início", senão o padrão do local, senão o automático); sem local, o
    # convite para criar o primeiro.
    def show
      @sites = Site.visible_to(current_user).order(:name).to_a
      @site = @sites.find { |s| s.id == params[:local] } || @sites.find { |s| s.id == current_user.dashboard_prefs["site"] } || @sites.first
      return render(:welcome) unless @site

      authorize_site!(@site, :view)
      @dashboard = Dashboard.default_for(@site, current_user, @site_role) or return render(:welcome)
      @dashboards = @site.dashboards.ordered.select { |d| d.visible_to?(@site_role) }
      @resolved = Dashboards::Resolver.new(@dashboard, role: @site_role).call
      @view = @resolved["views"].find { |v| v["id"] == params[:view] } || @resolved["views"].first
      @home = true
      render "web/dashboards/show"
    end
  end
end
