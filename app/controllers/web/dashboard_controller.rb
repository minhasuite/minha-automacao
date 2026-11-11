module Web
  class DashboardController < ApplicationController
    # Início: o painel padrão da pessoa no local dela (o escolhido em "Abrir no
    # Início", senão o padrão do local, senão o automático); sem local, o
    # convite para criar o primeiro.
    def show
      return redirect_to(onboarding_path) if Onboarding.pending?(current_user)

      @sites = Site.visible_to(current_user).order(:name).to_a
      device = panel_device
      @site = @sites.find { |s| s.id == params[:local] } || (@sites.find { |s| s.id == device.dashboard.site_id } if device&.dashboard) ||
              @sites.find { |s| s.id == current_user.dashboard_prefs["site"] } || @sites.first
      return render(:welcome) unless @site

      authorize_site!(@site, :view)
      @dashboard = Dashboard.default_for(@site, current_user, @site_role, device: device) or return render(:welcome)
      @dashboards = @site.dashboards.ordered.select { |d| d.visible_to?(@site_role) }
      @resolved = Dashboards::Hero.apply!(Dashboards::Resolver.cached(@dashboard, role: @site_role).deep_dup, site: @site, user: current_user)
      Dashboards::Personal.apply!(@resolved, site: @site, user: current_user, role: @site_role)
      # A visão do aparelho (ideia 10) vale quando a URL não pede outra; depois o contexto (`open_if`).
      @view = Dashboards.pick_view(@resolved, params[:view].presence || (device.view if device&.dashboard_id == @dashboard.id))
      @home = true
      load_kiosk
      render "web/dashboards/show"
    end

    private

    # Ideia 10: o aparelho deste pedido (cookie da web ou cabeçalho do app), marcado como visto.
    def panel_device
      PanelDevice.current(request, cookies)&.tap { |d| d.seen!(request.user_agent) }
    end

    # Leitor (viewer) vê o painel e o que ele abre; comando e cadastro barram pelo papel.
    def viewer_allowed? = true
  end
end
