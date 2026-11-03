require "digest"

# Token opaco da API: par access (30 min) + refresh (60 dias, rotacionado a
# cada uso, com detecção de reuso). Guarda só digests SHA-256. Não é
# tenant-scoped: a autenticação roda antes de fixar a empresa.
class ApiToken < ApplicationRecord
  belongs_to :user

  ACCESS_TTL = 30.minutes
  REFRESH_TTL = 60.days

  scope :active, -> { where(revoked_at: nil) }
  # Token do app (sem cliente externo); o da Alexa só vale em /alexa/smart_home.
  scope :app, -> { where(client: nil) }
  scope :alexa, -> { where(client: "alexa") }

  belongs_to :site, optional: true

  ALEXA_CODE_TTL = 5.minutes

  # => [registro, access_plain, refresh_plain]
  def self.issue(user, device_name: nil)
    access = generate_token
    refresh = generate_token
    token = create!(user: user, access_token_digest: digest(access), refresh_token_digest: digest(refresh),
                    access_expires_at: ACCESS_TTL.from_now, refresh_expires_at: REFRESH_TTL.from_now,
                    device_name: device_name.presence)
    [ token, access, refresh ]
  end

  def self.find_by_access(plain)
    return if plain.blank?

    active.app.where(access_token_digest: digest(plain)).where("access_expires_at > ?", Time.current).first
  end

  def self.find_by_refresh(plain, scope: active.app)
    return if plain.blank?

    scope.where(refresh_token_digest: digest(plain)).where("refresh_expires_at > ?", Time.current).first
  end

  # Refresh que casa com o digest ANTERIOR de um token ativo = alguém reusou
  # um token já rotacionado (indício de roubo).
  def self.reused(plain)
    return if plain.blank?

    active.app.find_by(previous_refresh_token_digest: digest(plain))
  end

  # --- Alexa (F9): account linking por OAuth 2.0 (authorization code) ------

  # Código de autorização = registro ainda não usado (5 min). → código em claro.
  # ondaC1 (C6): o mesmo fluxo para o Google Home (`client: "google"`, OauthClients).
  CLIENT_NAMES = { "alexa" => "Alexa", "google" => "Google Home" }.freeze

  def self.alexa_code!(user, site, redirect_uri) = code!(user, site, redirect_uri, client: "alexa")

  def self.code!(user, site, redirect_uri, client:)
    code = generate_token
    create!(user: user, site: site, client: client, redirect_uri: redirect_uri, device_name: "#{CLIENT_NAMES.fetch(client, client)} (#{site.name})",
            access_token_digest: digest(code), refresh_token_digest: digest(generate_token),
            access_expires_at: ALEXA_CODE_TTL.from_now, refresh_expires_at: ALEXA_CODE_TTL.from_now)
    code
  end

  # --- MCP (ondaB1, B7): token de longa duração de uma pessoa num local ----
  MCP_TTL = 1.year
  scope :mcp, -> { where(client: "mcp") }

  # → [registro, token em claro] (o claro só aparece uma vez).
  def self.mcp!(user, site, name)
    plain = "ma_mcp_#{generate_token}"
    token = create!(user: user, site: site, client: "mcp", device_name: name.to_s.squish.first(60).presence || "MCP",
                    access_token_digest: digest(plain), refresh_token_digest: digest(generate_token),
                    access_expires_at: MCP_TTL.from_now, refresh_expires_at: MCP_TTL.from_now)
    [ token, plain ]
  end

  def self.find_mcp(plain)
    return if plain.blank?

    active.mcp.where(access_token_digest: digest(plain)).where("access_expires_at > ?", Time.current).first
  end

  # Troca o código (uma vez só: a rotação muda o digest) → [registro, access, refresh] ou nil.
  def self.redeem_alexa_code(code, redirect_uri) = redeem_code(code, redirect_uri, client: "alexa")

  def self.redeem_code(code, redirect_uri, client:)
    token = active.where(client: client, last_used_at: nil, access_token_digest: digest(code)).where("access_expires_at > ?", Time.current).first
    return unless token && token.redirect_uri == redirect_uri.to_s

    [ token, *token.rotate! ]
  end

  # Access token da diretiva Smart Home (só depois da troca do código).
  def self.find_alexa(plain) = find_client_token(plain, "alexa")

  def self.find_client_token(plain, client)
    return if plain.blank?

    active.where(client: client).where.not(last_used_at: nil).where(access_token_digest: digest(plain)).where("access_expires_at > ?", Time.current).first
  end

  # Janela deslizante: cada rotação estende o refresh por mais 60 dias.
  def rotate!
    access = self.class.generate_token
    refresh = self.class.generate_token
    update!(previous_refresh_token_digest: refresh_token_digest,
            access_token_digest: self.class.digest(access), refresh_token_digest: self.class.digest(refresh),
            access_expires_at: ACCESS_TTL.from_now, refresh_expires_at: REFRESH_TTL.from_now,
            last_used_at: Time.current)
    [ access, refresh ]
  end

  def revoke! = update!(revoked_at: Time.current)

  def touch_usage!
    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def self.generate_token = SecureRandom.urlsafe_base64(32)
  def self.digest(plain) = Digest::SHA256.hexdigest(plain.to_s)
end
