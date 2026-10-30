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
  SITUATIONS = { "online" => "Respondendo", "offline" => "Sem resposta", "error" => "Com erro", "new" => "Novo",
                 "removed" => "Removido da conta" }.freeze
  NEW_FOR = 7.days

  scope :in_situation, lambda { |s|
    case s
    when "removed" then where.not(removed_at: nil)
    when "error" then where(removed_at: nil).where("devices.last_error IS NOT NULL OR devices.status = 'error'")
    when "offline" then where(removed_at: nil, status: "offline")
    when "new" then where(removed_at: nil).where(created_at: NEW_FOR.ago..)
    when "online" then where(removed_at: nil, status: "online", last_error: nil)
    else all
    end
  }

  def situation
    return "removed" if removed_at
    return "error" if last_error.present? || status == "error"
    return "offline" if status == "offline"

    created_at && created_at > NEW_FOR.ago ? "new" : "online"
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
  def usages
    ids = points.pluck(:id, :key).flatten.compact
    return [] if ids.empty?

    like = ids.map { |v| "%#{self.class.sanitize_sql_like(v)}%" }
    point_ids = points.select(:id)
    [
      [ "Painel", site.dashboards.where("definition::text LIKE ANY (ARRAY[?])", like) ],
      [ "Automação", site.automations.where("definition::text LIKE ANY (ARRAY[?])", like) ],
      [ "Cena", site.scenes.where("items::text LIKE ANY (ARRAY[?])", like) ],
      [ "Espelhamento", site.point_links.where(source_point_id: point_ids).or(site.point_links.where(target_point_id: point_ids)) ],
      [ "Aviso", site.notify_rules.where(point_id: point_ids) ],
      [ "Alerta", site.alert_rules.where(point_id: point_ids) ],
      [ "Agenda", site.schedules.where(point_id: point_ids) ]
    ].flat_map { |label, scope| scope.map { |r| [ label, r ] } }
  end

  private

  def area_in_same_site
    errors.add(:area, "precisa ser deste local") if area && area.site_id != site_id
  end
end
