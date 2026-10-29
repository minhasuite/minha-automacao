# Dispositivo do local. Na F1 só o driver `virtual` executa comando; os outros
# entram no cadastro e passam a funcionar com os drivers (F3).
class Device < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  DRIVERS = { "virtual" => "Virtual (sem aparelho)", "tuya_local" => "Tuya local", "tuya_cloud" => "Tuya nuvem",
              "xiaomi_miot" => "Xiaomi", "alexa" => "Alexa", "mqtt" => "MQTT", "modbus_tcp" => "Modbus TCP",
              "onvif" => "Câmera ONVIF", "go2rtc" => "Câmera (go2rtc)" }.freeze
  STATUSES = %w[online offline error].freeze

  belongs_to :site
  belongs_to :area, optional: true
  has_many :points, dependent: nil # cascade no banco

  validates :name, presence: true
  validates :driver, inclusion: { in: DRIVERS.keys }
  validates :status, inclusion: { in: STATUSES }
  validate :area_in_same_site

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name, :driver, :area_id

  def virtual? = driver == "virtual"
  def driver_label = DRIVERS.fetch(driver, driver)

  private

  def area_in_same_site
    errors.add(:area, "precisa ser deste local") if area && area.site_id != site_id
  end
end
