# id_token do Google de mentira, assinado por uma chave RSA de teste: o
# GoogleLogin confere de verdade (assinatura, iss, aud, exp, e-mail
# verificado); só as chaves públicas do Google são trocadas pela de teste.
module GoogleIdTokenHelpers
  GOOGLE_TEST_KEY = OpenSSL::PKey::RSA.generate(2048)
  GOOGLE_TEST_CLIENT = "cliente-web-teste.apps.googleusercontent.com".freeze

  def google_login_on!(client_id: GOOGLE_TEST_CLIENT, audiences: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GOOGLE_CLIENT_ID").and_return(client_id)
    allow(ENV).to receive(:[]).with("GOOGLE_LOGIN_AUDIENCES").and_return(audiences)
    keys = Google::Auth::IDTokens::StaticKeySource.new(
      [ Google::Auth::IDTokens::KeyInfo.new(id: "chave-teste", key: GOOGLE_TEST_KEY.public_key, algorithm: "RS256") ]
    )
    allow(Google::Auth::IDTokens).to receive(:oidc_key_source).and_return(keys)
  end

  def google_id_token(sub: "g-1", email: "gil@ex.com", email_verified: true, name: "Gil Teste",
                      aud: GOOGLE_TEST_CLIENT, iss: "https://accounts.google.com", exp: 1.hour.from_now, key: GOOGLE_TEST_KEY)
    payload = { iss: iss, aud: aud, sub: sub, email: email, email_verified: email_verified, name: name,
                iat: Time.now.to_i, exp: exp.to_i }
    JWT.encode(payload, key, "RS256", { kid: "chave-teste" })
  end
end

RSpec.configure { |c| c.include GoogleIdTokenHelpers }
