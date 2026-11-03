# Passkeys (ondaA2 A16; WebAuthn sem gem). O navegador entrega a chave
# pública pronta (`response.getPublicKey()`, SPKI DER) e os dados do
# autenticador (`getAuthenticatorData()`), então não precisa de CBOR: o
# servidor confere desafio, origem, hash do RP e a flag de presença e, no
# login, a assinatura sobre authenticatorData + SHA-256(clientDataJSON).
# Sem atestação (como quase todo site): vale a chave que a pessoa registrou logada.
module Passkeys
  Error = Class.new(StandardError)
  ALGS = [ -7, -257 ].freeze # ES256, RS256

  ANDROID_PACKAGE = "com.minhasuite.minhaautomacao".freeze

  module_function

  # appweb2: impressões do certificado do app (`AA:BB:…`) e as origens que o
  # Credential Manager manda (`android:apk-key-hash:<sha256 em base64url>`).
  def android_prints = ENV["ANDROID_APP_CERT_SHA256"].to_s.split(",").map { |s| s.strip.upcase }.grep(/\A(\h\h:){31}\h\h\z/)
  def android_origins = android_prints.map { |p| "android:apk-key-hash:#{b64([ p.delete(':') ].pack('H*'))}" }

  def b64(bin) = Base64.urlsafe_encode64(bin, padding: false)
  def unb64(text) = Base64.urlsafe_decode64(text.to_s + ("=" * ((4 - (text.to_s.length % 4)) % 4)))
  def challenge = b64(SecureRandom.random_bytes(32))

  # appweb2: o JSON do Credential Manager (`{id, response: {…}}`) no formato
  # plano que o navegador manda (id, clientDataJSON, authenticatorData, …).
  def from_credential(cred)
    cred = cred.respond_to?(:to_unsafe_h) ? cred.to_unsafe_h : (cred.is_a?(String) ? JSON.parse(cred) : cred.to_h)
    resp = cred["response"].to_h
    { id: cred["id"], clientDataJSON: resp["clientDataJSON"], authenticatorData: resp["authenticatorData"],
      signature: resp["signature"], publicKey: resp["publicKey"], name: cred["name"] }.with_indifferent_access
  rescue JSON::ParserError, TypeError, NoMethodError
    raise Error, "credencial"
  end

  def creation_options(user, rp_id:, challenge:)
    { challenge: challenge, rp: { id: rp_id, name: "Minha Automação" },
      user: { id: b64(user.id.to_s), name: user.email, displayName: user.name },
      pubKeyCredParams: ALGS.map { |a| { type: "public-key", alg: a } }, timeout: 120_000, attestation: "none",
      authenticatorSelection: { residentKey: "required", userVerification: "preferred" },
      excludeCredentials: user.passkeys.map { |p| { type: "public-key", id: p.credential_id } } }
  end

  def request_options(rp_id:, challenge:) = { challenge: challenge, rpId: rp_id, timeout: 120_000, userVerification: "preferred", allowCredentials: [] }

  # → Passkey nova do usuário (params do navegador: id, clientDataJSON, authenticatorData, publicKey, name).
  def register!(user, params, challenge:, origin:, rp_id:)
    auth = check_client!(params, "webauthn.create", challenge, origin, rp_id)
    key = OpenSSL::PKey.read(unb64(params[:publicKey]))
    raise Error, "chave" unless key.is_a?(OpenSSL::PKey::EC) || key.is_a?(OpenSSL::PKey::RSA)

    user.passkeys.create!(name: params[:name].to_s.squish.presence&.truncate(60) || "Passkey", credential_id: params[:id].to_s,
                          public_key: b64(key.public_to_der), sign_count: auth[:count])
  rescue OpenSSL::PKey::PKeyError, ArgumentError, ActiveRecord::RecordInvalid => e
    raise Error, e.message
  end

  # → Passkey que entrou (params: id, clientDataJSON, authenticatorData, signature).
  def authenticate!(params, challenge:, origin:, rp_id:)
    passkey = Passkey.find_by(credential_id: params[:id].to_s) or raise(Error, "desconhecida")
    auth = check_client!(params, "webauthn.get", challenge, origin, rp_id)
    signed = unb64(params[:authenticatorData]) + Digest::SHA256.digest(unb64(params[:clientDataJSON]))
    key = OpenSSL::PKey.read(unb64(passkey.public_key))
    raise Error, "assinatura" unless key.verify("SHA256", unb64(params[:signature]), signed)
    raise Error, "contador" if passkey.sign_count.positive? && auth[:count] <= passkey.sign_count # chave clonada

    passkey.update!(sign_count: auth[:count], last_used_at: Time.current)
    passkey
  rescue OpenSSL::PKey::PKeyError, ArgumentError => e
    raise Error, e.message
  end

  def check_client!(params, type, challenge, origin, rp_id)
    client = JSON.parse(unb64(params[:clientDataJSON]))
    raise Error, "tipo" unless client["type"] == type
    raise Error, "desafio" unless challenge.present? && ActiveSupport::SecurityUtils.secure_compare(client["challenge"].to_s, challenge)
    raise Error, "origem" unless Array(origin).include?(client["origin"])

    data = unb64(params[:authenticatorData])
    raise Error, "rp" unless data.bytesize >= 37 && ActiveSupport::SecurityUtils.secure_compare(data.byteslice(0, 32), Digest::SHA256.digest(rp_id))
    raise Error, "presença" unless data.getbyte(32).anybits?(0x01)

    { count: data.byteslice(33, 4).unpack1("N") }
  rescue JSON::ParserError
    raise Error, "cliente"
  end
end
