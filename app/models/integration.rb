# Conta de um serviço externo usada por vários aparelhos (F8: Alexa). Guarda
# as credenciais cifradas e o estado da última conversa com o serviço.
class Integration < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  DRIVERS = { "alexa" => "Alexa (Amazon)" }.freeze
  STATUSES = { "pending" => "Aguardando", "ok" => "Funcionando", "error" => "Com erro" }.freeze

  belongs_to :site
  has_many :devices, dependent: nil # o banco solta (on_delete nullify)

  encrypts :credentials

  validates :name, presence: true
  validates :driver, inclusion: { in: DRIVERS.keys }
  validates :status, inclusion: { in: STATUSES.keys }

  audited_attributes :name, :driver

  def driver_label = DRIVERS.fetch(driver, driver)
  def status_label = STATUSES.fetch(status, status)

  def ok! = update_columns(status: "ok", last_error: nil, last_ok_at: Time.current)
  def error!(message) = update_columns(status: "error", last_error: message.to_s.truncate(255))

  # Credenciais em JSON ({} se vazias ou ilegíveis).
  def secrets
    JSON.parse(credentials.presence || "{}")
  rescue JSON::ParserError
    {}
  end
end
