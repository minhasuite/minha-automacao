# Instalação de um cliente acompanhada pela central do integrador (Integrator, só com INTEGRATOR_HUB=1).
# O token (mostrado uma vez, ao criar) vai no INTEGRATOR_TOKEN do servidor do cliente; aqui só o digest.
# `last_report` = o último resumo (Integrator::Report); `alerts` = os avisos ativos ({chave → desde}), para avisar
# uma vez e avisar de novo no "voltou"; `max_version` = freio: o cliente não atualiza além dela.
class Installation < ApplicationRecord
  acts_as_tenant :tenant

  STATUSES = %w[waiting ok warn error offline].freeze
  SAMPLE_KEEP = 30.days

  has_many :samples, class_name: "InstallationSample", dependent: nil # cascade no banco

  validates :name, presence: true, length: { maximum: 80 }, uniqueness: { scope: :tenant_id }
  validates :status, inclusion: { in: STATUSES }
  validates :max_version, format: { with: /\Av\d+\.\d+\.\d+(-beta\.\d+)?\z/ }, allow_blank: true

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :max_version, with: ->(v) { v.to_s.strip.presence }

  # → [instalação, token em claro] (o token só existe nesta resposta).
  def self.create_with_token!(**attrs)
    token = "ma_inst_#{SecureRandom.urlsafe_base64(32)}"
    [ create!(**attrs, token_digest: digest(token)), token ]
  end

  def self.digest(token) = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "installation:#{token}")

  # Pelo token do resumo (sem empresa atual: a API do resumo não tem sessão).
  def self.find_by_token(token)
    return if token.blank?

    ActsAsTenant.without_tenant { find_by(token_digest: digest(token)) }
  end

  def report = last_report.to_h
  def server = report["server"].to_h
  def backup = report["backup"].to_h
  def house = report["house"].to_h
  def health = report["health"].to_h

  # Grava o resumo que chegou (e uma amostra para os gráficos).
  def receive!(payload, now: Time.current)
    update!(last_report: payload, last_seen_at: now, version_tag: payload.dig("version", "tag"))
    s = payload["server"].to_h
    InstallationSample.insert_all!([ { installation_id: id, at: now, temp: s["temp"], cpu: s["cpu"], memory: s["memory"],
                                       disk_used: s.dig("disk", "used"), online: s["online"] } ])
  end
end
