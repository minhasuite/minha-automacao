# Papel por local (SiteMembership), igual na web e na API. Sem acesso ao local
# = não encontrado (não revela que existe); papel baixo = Forbidden.
module SiteAuthorization
  extend ActiveSupport::Concern

  private

  def authorize_site!(site, action, risk: nil)
    @site_role = site.role_for(current_user) or raise ActiveRecord::RecordNotFound
    raise SiteMembership::Forbidden, "Seu papel neste local não permite isso." unless SiteMembership.allowed?(@site_role, action, risk: risk)

    @site_role
  end

  def can?(action, risk: nil) = SiteMembership.allowed?(@site_role, action, risk: risk)
end
