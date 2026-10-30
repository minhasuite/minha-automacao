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

  validates :poll_s, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # Formulário em minutos (vazio ou 0 = não lê).
  def poll_min = poll_s && (poll_s / 60.0).round(2).to_s.delete_suffix(".0")
  def poll_min=(value)
    self.poll_s = value.blank? ? nil : (value.to_s.tr(",", ".").to_f * 60).round
  end

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
