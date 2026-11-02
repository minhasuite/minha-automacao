# Papel por local (SiteMembership), igual na web e na API. Sem acesso ao local
# = não encontrado (não revela que existe); papel baixo = Forbidden.
module SiteAuthorization
  extend ActiveSupport::Concern

  private

  def authorize_site!(site, action, risk: nil)
    @site_role = site.role_for(current_user) or raise ActiveRecord::RecordNotFound
    raise SiteMembership::Forbidden, I18n.t("notices.forbidden") unless SiteMembership.allowed?(@site_role, action, risk: risk)
    raise SiteMembership::Forbidden, I18n.t("notices.viewer_only") if @site_role == "viewer" && !viewer_allowed?

    @site_role
  end

  def can?(action, risk: nil) = SiteMembership.allowed?(@site_role, action, risk: risk)

  # Leitor só passa nos controllers que mostram painel (eles devolvem true).
  def viewer_allowed? = false

  # IP, usuário/endereço de câmera, token e MAC só para técnico ou dono.
  def reveal_sensitive? = Sensitive.reveal?(@site_role)
end
