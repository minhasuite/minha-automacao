# A empresa. Tudo que é dela pertence ao tenant; os membros são
# os usuários com o mesmo tenant_id. Sem planos nem assinatura: o produto é
# aberto e tudo é liberado.
class Tenant < ApplicationRecord
  include Auditable

  TIMEZONE = "America/Sao_Paulo".freeze

  has_many :users, dependent: :destroy

  validates :name, presence: true
  validates :uf, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true

  normalizes :uf, with: ->(v) { v.to_s.strip.upcase.presence }
  normalizes :document, :phone, with: ->(v) { v.to_s.gsub(/\D/, "").presence }

  def timezone = TIMEZONE

  # Cliente OAuth da skill Smart Home (F9): id e as URLs de retorno da Amazon
  # ficam em `settings["alexa"]`; o segredo só como digest (aparece uma vez).
  def alexa = settings["alexa"] || {}
  def alexa_client_id = alexa["client_id"]
  def alexa_redirect_uris = Array(alexa["redirect_uris"])
  def alexa_secret_ok?(plain) = alexa["secret_digest"].present? && ActiveSupport::SecurityUtils.secure_compare(alexa["secret_digest"], ApiToken.digest(plain))

  def self.find_by_alexa_client(id) = id.present? ? where("settings->'alexa'->>'client_id' = ?", id.to_s).first : nil

  # → segredo em claro (só nesta resposta). Mantém o id se já existe.
  def generate_alexa_client!(redirect_uris)
    secret = SecureRandom.urlsafe_base64(32)
    update!(settings: settings.merge("alexa" => { "client_id" => alexa_client_id || "ma-#{SecureRandom.hex(8)}", "secret_digest" => ApiToken.digest(secret),
                                                  "redirect_uris" => self.class.redirect_list(redirect_uris) }))
    secret
  end

  def update_alexa_redirects!(text) = update!(settings: settings.merge("alexa" => alexa.merge("redirect_uris" => self.class.redirect_list(text))))
  def self.redirect_list(text) = text.to_s.split(/\s+/).select { |u| u.start_with?("https://") }.uniq.first(5)

  # Endereços internos liberados para a saída HTTP (SafeHttp): host ou CIDR.
  def http_allow = Array(settings["http_allow"])
  def http_allow_text = http_allow.join("\n")
  def http_allow_text=(text)
    self.settings = settings.merge("http_allow" => text.to_s.split(/[\s,]+/).map(&:strip).compact_blank.uniq.first(50))
  end
end
