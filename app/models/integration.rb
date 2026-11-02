# Conta de um serviço externo usada por vários aparelhos (F8/F8c). Guarda as
# credenciais cifradas, o estado da última conversa com o serviço e a última
# lista de aparelhos da conta (`inventory`, cifrado: leva local_key/token).
# A varredura e a adoção ficam em `Integrations`.
class Integration < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  # Rótulos em integrations.statuses.<status> (config/locales/integrations.*.yml).
  STATUSES = %w[pending ok error syncing].freeze
  SYNC_S = 6 * 3600 # varredura da conta: padrão 6 h

  belongs_to :site
  has_many :devices, dependent: nil # o banco solta (on_delete nullify)

  encrypts :credentials
  encrypts :inventory

  validates :name, presence: true
  validates :driver, inclusion: { in: ->(_) { Integrations.drivers } }
  validates :status, inclusion: { in: STATUSES }

  validates :poll_s, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # Formulário em minutos (vazio ou 0 = não lê).
  def poll_min = poll_s && (poll_s / 60.0).round(2).to_s.delete_suffix(".0")
  def poll_min=(value)
    self.poll_s = value.blank? ? nil : (value.to_s.tr(",", ".").to_f * 60).round
  end

  audited_attributes :name, :driver

  # Tipo (nome, ícone, assistente, varredura) vem do plugin registrado.
  def plugin = Integrations.for_driver(driver)
  def driver_label = plugin&.title || driver
  def status_label = STATUSES.include?(status) ? I18n.t(status, scope: "integrations.statuses") : status
  def icon_name = plugin&.icon || "link"
  def account = settings["account"].presence

  def ok! = update_columns(status: "ok", last_error: nil, last_ok_at: Time.current, settings: settings.except("auth_error"))

  # Recebe a exceção (ou só o texto). Credencial (Integrations::AuthError) liga `auth_error?`.
  def error!(error)
    update_columns(status: "error", last_error: (error.try(:message) || error).to_s.truncate(255),
                   settings: settings.merge("auth_error" => error.is_a?(Integrations::AuthError)))
  end

  def auth_error? = settings["auth_error"] == true

  # Credenciais em JSON ({} se vazias ou ilegíveis).
  def secrets
    JSON.parse(credentials.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def merge_secrets!(values) = update!(credentials: secrets.merge(values.stringify_keys).to_json)

  # Aparelhos da última varredura ([] se nunca varreu).
  def found
    Array(JSON.parse(inventory.presence || "[]"))
  rescue JSON::ParserError
    []
  end
end
