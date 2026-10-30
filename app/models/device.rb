# Dispositivo do local. Executam comando os drivers de `Drivers::REGISTRY`
# (virtual, tuya_local, mqtt, xiaomi_miot e alexa); go2rtc é câmera (só
# visualização) e os outros entram só no cadastro por enquanto. Leitura
# periódica: `poll_s` (padrão 30 min; nulo ou 0 desliga), ver `Polling`.
# Xiaomi: `address` {host, model}, `external_id` = did, `credential` = token.
# Alexa: `integration` (conta), `external_id` = número de série da Echo.
# Tuya local: `address` {host, version, port}, `external_id` = device_id,
# `credential` = local_key (cifrada), `listen` liga o ouvinte persistente.
class Device < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  DRIVERS = { "virtual" => "Virtual (sem aparelho)", "tuya_local" => "Tuya local", "tuya_cloud" => "Tuya nuvem",
              "xiaomi_miot" => "Xiaomi", "alexa" => "Alexa", "mqtt" => "MQTT", "modbus_tcp" => "Modbus TCP",
              "onvif" => "Câmera ONVIF", "go2rtc" => "Câmera (go2rtc)" }.freeze
  STATUSES = %w[online offline error].freeze

  belongs_to :site
  belongs_to :area, optional: true
  belongs_to :integration, optional: true
  has_many :points, dependent: nil # cascade no banco

  encrypts :credential

  validates :name, presence: true
  validates :driver, inclusion: { in: DRIVERS.keys }
  validates :status, inclusion: { in: STATUSES }
  validate :area_in_same_site

  normalizes :name, with: ->(v) { v.to_s.squish }

  validates :poll_s, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # Formulário em minutos (vazio ou 0 = não lê).
  def poll_min = poll_s && (poll_s / 60.0).round(2).to_s.delete_suffix(".0")
  def poll_min=(value)
    self.poll_s = value.blank? ? nil : (value.to_s.tr(",", ".").to_f * 60).round
  end

  audited_attributes :name, :driver, :area_id

  def virtual? = driver == "virtual"
  def tuya_local? = driver == "tuya_local"
  def driver_label = DRIVERS.fetch(driver, driver)

  private

  def area_in_same_site
    errors.add(:area, "precisa ser deste local") if area && area.site_id != site_id
  end
end
