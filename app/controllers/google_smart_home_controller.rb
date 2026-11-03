# Google Home cloud-to-cloud (ondaC1, C6), sem sessão: o Google manda as
# intenções com o access token do account linking no cabeçalho
# Authorization (POST /google/smart_home). O token vem do /oauth/token comum
# (OauthClients). Toda resposta é 200 com o `errorCode` do Google, como ele pede;
# token inválido = 401 (o Google renova pelo refresh token).
class GoogleSmartHomeController < ActionController::API
  def fulfill
    token = request.authorization.to_s[/\ABearer\s+(\S+)\z/, 1]
    return head(:unauthorized) unless ApiToken.find_client_token(token, "google")

    body = JSON.parse(request.raw_post.presence || "{}")
    render json: GoogleHome.handle(body, token)
  rescue JSON::ParserError
    render json: { "payload" => { "errorCode" => "protocolError" } }, status: :bad_request
  end
end
