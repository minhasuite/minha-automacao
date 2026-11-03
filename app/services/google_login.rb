# Entrar com Google (web e app, padrão da suíte): o botão do Google (GIS) na
# web e o google_sign_in no app entregam um id_token; aqui ele é conferido
# (assinatura do Google, validade, audiência = clients configurados e e-mail
# verificado). Sem GOOGLE_CLIENT_ID, o login com Google não existe (o botão some).
#
# - GOOGLE_CLIENT_ID: client **web** (o do botão; o app pede o token para ele
#   como `serverClientId`, então o `aud` do token do app também é ele).
# - GOOGLE_LOGIN_AUDIENCES: outros clients aceitos, separados por vírgula (opcional).
module GoogleLogin
  class Error < StandardError; end

  module_function

  def client_id = ENV["GOOGLE_CLIENT_ID"].presence
  def enabled? = client_id.present?
  def audiences = [ client_id, *ENV["GOOGLE_LOGIN_AUDIENCES"].to_s.split(",").map(&:strip) ].compact_blank.uniq

  # O Google só aceita origem https com domínio (ou localhost): acessando por
  # IP ou por nome .local (rede de casa) o botão não funcionaria, então some.
  def usable_host?(host)
    host = host.to_s.downcase
    host == "localhost" || !(host.match?(/\A[\d.]+\z/) || host.include?(":") || host.end_with?(".local"))
  end

  # → payload do token (sub, email, name...). Levanta Error se não vale.
  def verify!(id_token)
    raise Error, "login com Google desligado" unless enabled?

    payload = Google::Auth::IDTokens.verify_oidc(id_token.to_s, aud: audiences)
    raise Error, "e-mail não verificado" unless payload["email"].present? && payload["email_verified"].to_s == "true"

    payload
  rescue Google::Auth::IDTokens::VerificationError => e
    raise Error, e.message
  end
end
