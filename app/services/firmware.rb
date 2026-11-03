# Atualização de firmware dos aparelhos (ondaA2 A18; a entidade `update` do
# HA). Cada aparelho que se atualiza ganha um ponto `update` (valor JSON
# {installed, latest, state, notes_url}). Provedor = classe `< Firmware::Provider`
# em app/services/firmware/providers.rb + nome em `PROVIDERS`: `handles?(device)`,
# `check(device)` (→ Hash, ou nil quando o próprio aparelho informa, como o
# Zigbee2MQTT) e `install!(device)`. A tela e a verificação diária só perguntam ao registro.
module Firmware
  PROVIDERS = %w[Shelly Zigbee2mqtt ZwaveJs Matter MqttDiscovery Tasmota Esphome].freeze
  Error = Class.new(StandardError)

  class Provider
    class << self
      attr_reader :key

      def describe(key:) = @key = key
      def handles?(_device) = false
      def check(_device) = nil
      def install!(_device) = raise(NotImplementedError)
    end
  end

  module_function

  def providers = PROVIDERS.map { |n| Providers.const_get(n) }
  def provider(device) = providers.find { |p| p.handles?(device) }

  # Normaliza o valor (o nosso ou o do Zigbee2MQTT: installed_version/latest_version).
  def view(value)
    v = value.is_a?(Hash) ? value : { "installed" => value.presence }.compact # resto: MQTT `update` só com a versão
    installed = v["installed"] || v["installed_version"]
    latest = v["latest"] || v["latest_version"] || installed
    state = v["state"].to_s
    state = latest.present? && latest.to_s != installed.to_s ? "available" : "up_to_date" unless %w[installing updating].include?(state)
    { installed: installed&.to_s, latest: latest&.to_s, state: state == "updating" ? "installing" : state, notes_url: v["notes_url"] }
  end

  def available?(point) = view(point.value)[:state] == "available"

  def ensure_point!(device, address: {})
    device.points.find_by(capability: "update") ||
      device.points.create!(site: device.site, name: I18n.t("firmware.point_name"), key: "firmware_#{device.id.first(8)}", capability: "update",
                            data_type: "json", writable: false, address: address)
  end

  # Pergunta ao aparelho e grava no ponto (nil = provedor não pergunta).
  def check!(device)
    p = provider(device) or return nil
    info = p.check(device) or return nil
    point = ensure_point!(device)
    point.report!(info.stringify_keys.merge("state" => info[:latest].to_s != info[:installed].to_s ? "available" : "up_to_date"))
    point
  end

  def check_all!
    ActsAsTenant.without_tenant do
      Device.where(removed_at: nil, disabled: false).includes(:integration, :site, :tenant).find_each { |d| safely(d) { ActsAsTenant.with_tenant(d.tenant) { check!(d) } } }
    end
  end

  def install!(point, user:)
    device = point.device
    p = provider(device) or raise Error, I18n.t("firmware.no_provider")
    p.install!(device)
    AuditEvent.create!(tenant_id: device.tenant_id, user_id: user&.id, action: "firmware.install", auditable_type: "Device", auditable_id: device.id,
                       details: view(point.value).slice(:installed, :latest))
    point.report!((point.value.is_a?(Hash) ? point.value : {}).merge("state" => "installing"))
  rescue Integrations::Error, Drivers::Mqtt::Error => e
    raise Error, e.message
  end

  def safely(device)
    yield
  rescue StandardError => e
    Rails.logger.warn("[firmware] #{device.name}: #{e.message}")
  end
end
