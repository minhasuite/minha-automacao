# Verificação em duas etapas (ondaA2 A16; os "módulos de MFA" do HA). Cada
# fator é um plugin em `FACTORS`: `key`, `enabled?(user)` e `verify!(user,
# code)` → true/false. Com algum fator ligado, o login por senha (web, API e
# Google) pede o código. Passkey (Passkeys) entra sem senha e sem código: ela
# já é posse + biometria/PIN do aparelho.
module Mfa
  FACTORS = %w[Totp RecoveryCodes].freeze

  module_function

  def factors = FACTORS.map { |n| const_get(n) }
  def required?(user) = factors.any? { |f| f.enabled?(user) }
  def verify(user, code) = code.to_s.strip.present? && factors.any? { |f| f.enabled?(user) && f.verify!(user, code.to_s.strip) }

  # App autenticador (RFC 6238: HMAC-SHA1, 30 s, 6 dígitos). Código usado não vale de novo.
  module Totp
    STEP = 30
    DRIFT = 1
    B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".freeze

    module_function

    def key = "totp"
    def enabled?(user) = user.otp_enabled_at.present?
    def new_secret = base32(SecureRandom.random_bytes(20))

    def uri(secret, email, issuer: "Minha Automação")
      label = ERB::Util.url_encode("#{issuer}:#{email}")
      "otpauth://totp/#{label}?secret=#{secret}&issuer=#{ERB::Util.url_encode(issuer)}&digits=6&period=#{STEP}"
    end

    def code(secret, step) = format("%06d", truncate(OpenSSL::HMAC.digest("SHA1", unbase32(secret), [ step ].pack("Q>"))))

    # → passo que casou ou nil (tolera um passo de relógio para cada lado).
    def match(secret, given, at: Time.now)
      now = at.to_i / STEP
      (now - DRIFT..now + DRIFT).find { |s| ActiveSupport::SecurityUtils.secure_compare(code(secret, s), given.to_s.delete(" ")) }
    end

    def verify!(user, given)
      step = match(user.otp_secret, given) or return false
      return false if user.otp_last_step.to_i >= step # repetição

      user.update_columns(otp_last_step: step) # rubocop:disable Rails/SkipsModelValidations
      true
    end

    def truncate(hmac)
      o = hmac.getbyte(-1) & 0x0f
      (hmac.byteslice(o, 4).unpack1("N") & 0x7fffffff) % 1_000_000
    end

    def base32(bytes) = bytes.unpack1("B*").scan(/.{1,5}/).map { |b| B32[b.ljust(5, "0").to_i(2)] }.join

    def unbase32(text) = [ text.to_s.upcase.delete("= ").chars.map { |c| B32.index(c).to_i.to_s(2).rjust(5, "0") }.join ].pack("B*")
  end

  # Códigos de recuperação (10, de uso único), guardados como digest.
  module RecoveryCodes
    COUNT = 10

    module_function

    def key = "recovery"
    def enabled?(user) = Array(user.otp_recovery).any?

    # Gera, grava os digests e devolve os códigos em claro (mostrados uma vez).
    def generate!(user)
      codes = Array.new(COUNT) { SecureRandom.alphanumeric(10).downcase.scan(/.{5}/).join("-") }
      user.update!(otp_recovery: codes.map { |c| digest(c) })
      codes
    end

    def verify!(user, given)
      d = digest(given.downcase.delete(" "))
      list = Array(user.otp_recovery)
      return false unless list.include?(d)

      user.update!(otp_recovery: list - [ d ])
      true
    end

    def digest(code) = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, code.to_s)
  end
end
