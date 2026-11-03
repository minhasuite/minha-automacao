# Clientes do account linking (OAuth 2.0, código de autorização) dos
# assistentes de fora (ondaC1, C6): a skill da Alexa (cliente da
# instalação, Tenant#alexa) e o projeto do Google Home (integração
# `google_home` do local). A tela /oauth/autorizar e o /oauth/token são os
# mesmos; o `kind` vira o `client` do ApiToken ("alexa", "google") e o token
# só vale no endpoint daquele assistente. Fonte nova = método + linha em `find`.
module OauthClients
  Client = Data.define(:kind, :tenant, :redirect_uris, :digest, :site_id) do
    def secret_ok?(plain) = digest.present? && ActiveSupport::SecurityUtils.secure_compare(digest, ApiToken.digest(plain.to_s))
  end

  module_function

  def find(id)
    return if id.blank?

    alexa(id) || google(id)
  end

  def alexa(id)
    t = Tenant.find_by_alexa_client(id) or return
    Client.new(kind: "alexa", tenant: t, redirect_uris: t.alexa_redirect_uris, digest: t.alexa["secret_digest"], site_id: nil)
  end

  def google(id)
    i = ActsAsTenant.without_tenant { Integration.where(driver: "google_home").find_by("settings->>'client_id' = ?", id.to_s) } or return
    Client.new(kind: "google", tenant: i.tenant, redirect_uris: Integrations::GoogleHomePlugin.redirect_uris(i), digest: i.settings["secret_digest"], site_id: i.site_id)
  end
end
