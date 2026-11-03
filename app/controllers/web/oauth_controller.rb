module Web
  # Tela de autorização do account linking da Alexa (F9): a pessoa entra (se
  # ainda não entrou), escolhe o local e permite; volta para a URL de retorno
  # da Amazon com o código (5 min, uso único). Cliente e URLs vêm da
  # instalação (Tenant#alexa): URL fora da lista não recebe nada.
  class OauthController < ApplicationController
    layout "auth"

    before_action :load_client

    def new
      @sites = sites.order(:name).to_a
    end

    def create
      site = sites.find(params[:site_id])
      return redirect_to(add_query(error: "access_denied"), allow_other_host: true) if params[:deny].present?

      code = ApiToken.code!(current_user, site, @redirect_uri, client: @client.kind)
      AuditEvent.create!(tenant_id: current_user.tenant_id, user_id: current_user.id, action: "#{@client.kind}.link",
                         auditable_type: "Site", auditable_id: site.id, details: { site: site.name })
      redirect_to add_query(code: code), allow_other_host: true
    end

    private

    # ondaC1 (C6): cliente da Alexa (instalação) ou do Google Home (um local só).
    def load_client
      @client = OauthClients.find(params[:client_id])
      unless @client && @client.tenant.id == current_user.tenant_id && (params[:response_type].nil? || params[:response_type] == "code")
        return render(plain: t("oauth.unknown_client"), status: :bad_request)
      end

      @redirect_uri = @client.redirect_uris.find { |u| u == params[:redirect_uri] } or
        render(plain: t("oauth.bad_redirect"), status: :bad_request)
    end

    def sites = @client.site_id ? Site.visible_to(current_user).where(id: @client.site_id) : Site.visible_to(current_user)

    def add_query(**extra)
      uri = URI.parse(@redirect_uri)
      uri.query = [ uri.query.presence, URI.encode_www_form(extra.merge(state: params[:state].to_s)) ].compact.join("&")
      uri.to_s
    end
  end
end
