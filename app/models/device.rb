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

  # Situação da lista de dispositivos (filtro): removido da conta > com erro >
  # sem resposta > novo (7 dias) > respondendo.
  SITUATIONS = { "online" => "Online", "offline" => "Offline", "error" => "Com erro", "new" => "Novo",
                 "removed" => "Removido da conta" }.freeze
  # "Novo" = adotado de uma varredura de conta (`discovered_at`) e ainda sem
  # nenhum contato; os demais seguem o último contato (status/erro).
  NEW_FOR = 7.days
  NEW_SQL = "COALESCE(devices.discovered_at > :since AND devices.last_seen_at IS NULL, false)".freeze

  scope :in_situation, lambda { |s|
    case s
    when "removed" then where.not(removed_at: nil)
    when "error" then where(removed_at: nil).where("devices.last_error IS NOT NULL OR devices.status = 'error'")
    when "offline" then where(removed_at: nil, status: "offline")
    when "new" then where(removed_at: nil, last_error: nil).where.not(status: %w[error offline]).where(NEW_SQL, since: NEW_FOR.ago)
    when "online" then where(removed_at: nil, status: "online", last_error: nil).where.not(NEW_SQL, since: NEW_FOR.ago)
    else all
    end
  }

  def situation
    return "removed" if removed_at
    return "error" if last_error.present? || status == "error"
    return "offline" if status == "offline"

    discovered_at && discovered_at > NEW_FOR.ago && last_seen_at.nil? ? "new" : "online"
  end

  # Endereço na rede (formulário): IP e versão do protocolo Tuya.
  def host = address["host"]
  def protocol_version = address["version"]

  def host=(value)
    self.address = address.merge("host" => value.to_s.strip.presence).compact
  end

  def protocol_version=(value)
    self.address = address.merge("version" => value.to_s.strip.presence).compact
  end

  # Onde os pontos deste aparelho aparecem: [rótulo, registro], para a página do dispositivo.
  def usages = Point.usages(site, points)

  private

  def area_in_same_site
    errors.add(:area, "precisa ser deste local") if area && area.site_id != site_id
  end
end
