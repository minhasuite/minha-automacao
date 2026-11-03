module Integrations
  # Proxy Bluetooth do ESPHome (integ2): uma placa ESP32 com
  # `bluetooth_proxy` por integração; a varredura ouve os anúncios por 10 s e
  # lista os sensores BLE que o `Ble` entende (Drivers::BleProxy).
  class BleProxyPlugin < LanPlugin
    describe key: "ble_proxy", title: "Proxy Bluetooth (ESPHome)", icon: "status-online",
             description: "Sensores Bluetooth (BTHome, Xiaomi, pvvx/ATC, Govee, iBeacon, Oral-B) pelo proxy Bluetooth do ESPHome: temperatura, umidade, bateria, movimento, abertura e presença."
    texts en: { title: "Bluetooth proxy (ESPHome)", description: "Bluetooth sensors (BTHome, Xiaomi, pvvx/ATC, Govee, iBeacon, Oral-B) through the ESPHome Bluetooth proxy: temperature, humidity, battery, motion, open/close and presence." },
          es: { title: "Proxy Bluetooth (ESPHome)", description: "Sensores Bluetooth (BTHome, Xiaomi, pvvx/ATC, Govee, iBeacon, Oral-B) mediante el proxy Bluetooth de ESPHome: temperatura, humedad, batería, movimiento, apertura y presencia." }
    port 6053
    secrets :encryption_key, :password, :bindkeys
    mdns "_esphomelib._tcp"

    def self.inventory(integration) = Drivers::BleProxy.entries(integration)

    # Uma escuta para todos os sensores adotados.
    def self.refresh(integration)
      devices = integration.devices.where(driver: driver, removed_at: nil, disabled: false).to_a
      return if devices.empty?

      seen = Drivers::BleProxy.listen(integration)
      devices.each { |d| (r = seen[d.address["mac"]]) && Drivers::BleProxy.apply(d, r[1]) }
    rescue Integrations::Error => e
      Rails.logger.warn("[ble_proxy] estado: #{e.message}")
    end
  end
end
