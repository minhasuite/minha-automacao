# Alexa Smart Home (F9), sem sessão: a diretiva que a Lambda repassa
# (`POST /alexa/smart_home`, o token vem dentro dela) e a troca de tokens do
# account linking (`POST /oauth/token`, RFC 6749: authorization_code e
# refresh_token, cliente por Basic ou no corpo). Cliente e URLs de retorno
# ficam na instalação (Tenant#alexa, tela "Expor para a Alexa").
class AlexaSmartHomeController < ActionController::API
  def smart_home
    body = JSON.parse(request.raw_post.presence || "{}")
    render json: Alexa::SmartHome.handle(body)
  rescue JSON::ParserError
    render json: Alexa::SmartHome.error_response({}, {}, Alexa::SmartHome::Error.new("INVALID_DIRECTIVE", "JSON inválido.")), status: :bad_request
  end

  # ondaC1 (C6): o mesmo token para o Google Home (cliente pelo OauthClients).
  def token
    client = oauth_client or return oauth_error("invalid_client", :unauthorized)
    tenant = client.tenant

    token, access, refresh = case params[:grant_type]
    when "authorization_code" then ApiToken.redeem_code(params[:code].to_s, params[:redirect_uri], client: client.kind)
    when "refresh_token"
      t = ApiToken.find_by_refresh(params[:refresh_token].to_s, scope: ApiToken.active.where(client: client.kind))
      [ t, *t.rotate! ] if t
    else return oauth_error("unsupported_grant_type")
    end
    return oauth_error("invalid_grant") unless token
    return token.revoke! && oauth_error("invalid_grant") unless token.user.tenant_id == tenant.id && !token.user.disabled?

    render json: { access_token: access, token_type: "Bearer", expires_in: ApiToken::ACCESS_TTL.to_i, refresh_token: refresh }
  end

  private

  def oauth_client
    id, secret = ActionController::HttpAuthentication::Basic.user_name_and_password(request) if request.authorization.to_s.start_with?("Basic ")
    id ||= params[:client_id]
    secret ||= params[:client_secret]
    client = OauthClients.find(id)
    client if client&.secret_ok?(secret)
  end

  def oauth_error(code, status = :bad_request) = render(json: { error: code }, status: status)
end
