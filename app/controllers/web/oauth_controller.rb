module Web
  # Tela de autorização do account linking da Alexa (F9): a pessoa entra (se
  # ainda não entrou), escolhe o local e permite; volta para a URL de retorno
  # da Amazon com o código (5 min, uso único). Cliente e URLs vêm da
  # instalação (Tenant#alexa): URL fora da lista não recebe nada.
  class OauthController < ApplicationController
    layout "auth"

    before_action :load_client

    def new
      @sites = Site.visible_to(current_user).order(:name).to_a
    end

    def create
      site = Site.visible_to(current_user).find(params[:site_id])
      return redirect_to(add_query(error: "access_denied"), allow_other_host: true) if params[:deny].present?

      code = ApiToken.alexa_code!(current_user, site, @redirect_uri)
      AuditEvent.create!(tenant_id: current_user.tenant_id, user_id: current_user.id, action: "alexa.link",
                         auditable_type: "Site", auditable_id: site.id, details: { site: site.name })
      redirect_to add_query(code: code), allow_other_host: true
    end

    private

    def load_client
      tenant = current_user.tenant
      unless params[:client_id].present? && tenant.alexa_client_id == params[:client_id] && (params[:response_type].nil? || params[:response_type] == "code")
        return render(plain: "Cliente da Alexa desconhecido nesta instalação.", status: :bad_request)
      end

      @redirect_uri = tenant.alexa_redirect_uris.find { |u| u == params[:redirect_uri] } or
        render(plain: "URL de retorno não cadastrada em Expor para a Alexa.", status: :bad_request)
    end

    def add_query(**extra)
      uri = URI.parse(@redirect_uri)
      uri.query = [ uri.query.presence, URI.encode_www_form(extra.merge(state: params[:state].to_s)) ].compact.join("&")
      uri.to_s
    end
  end
end
