module Web
  # Configurações → Painéis → Convidados (ideia 11): links temporários de
  # convidado/babá. Criar e revogar só o dono do local (`:admin`, o mesmo de
  # gerenciar membros); o link mostra só os widgets marcados com
  # `"guest": true`, com papel `viewer` ou `guest`. O link em claro aparece só
  # na resposta da criação (nunca em flash nem na lista).
  class GuestLinksController < ApplicationController
    def index
      @sites = owned_sites
      @links = GuestLink.where(site_id: @sites.map(&:id)).includes(:dashboard, :site, :created_by).order(created_at: :desc).limit(100).to_a
      @dashboards = @sites.flat_map { |s| Dashboard.ensure_for(s).map { |d| [ "#{s.name} · #{d.name}", d.id ] } }
    end

    def create
      p = params.require(:guest_link).permit(:dashboard_id, :name, :hours)
      role = params.dig(:guest_link, :role).to_s.presence_in(GuestLink::ROLES) || "viewer" # só viewer/guest, nunca papel maior
      dashboard = Dashboard.where(site_id: owned_sites.map(&:id)).find(p[:dashboard_id])
      _link, token = GuestLink.generate!(site: dashboard.site, dashboard: dashboard, name: p[:name], role: role,
                                         hours: p[:hours], created_by: current_user)
      @guest_url = guest_url(token)
      index
      render :index
    end

    def destroy
      link = GuestLink.where(site_id: owned_sites.map(&:id)).find(params[:id])
      link.revoke!
      redirect_to settings_guest_links_path, notice: t("guest_links.revoked", name: link.name)
    end

    private

    def owned_sites = Site.visible_to(current_user).order(:name).select { |s| SiteMembership.allowed?(s.role_for(current_user), :admin) }
  end
end
