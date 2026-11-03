module Integrations
  # Coordenador SMLIGHT SLZB (resto, grupo 9 #60; o `smlight` do HA) pela API
  # local do aparelho (/ha_info e /ha_sensors): temperatura do ESP e do chip
  # Zigbee, memória, ligado há, rede, modo do coordenador e as versões do
  # firmware (núcleo e Zigbee), que o Firmware compara com as publicadas pela
  # SMLIGHT. O Zigbee em si segue pelo Zigbee2MQTT (porta TCP do SLZB).
  class SmlightPlugin < SchemaPlugin
    describe key: "smlight", title: "SMLIGHT SLZB", icon: "chip",
             description: "Coordenadores Zigbee SLZB-06/07/MR: temperatura, memória, rede, modo e versão do firmware, com aviso de firmware novo."
    texts "pt-BR" => { points: { esp_temp: "Temperatura do ESP", zb_temp: "Temperatura do Zigbee", ram: "Memória usada", ethernet: "Cabo de rede",
                                 mode: "Modo do coordenador", core: "Firmware do núcleo", zigbee: "Firmware do Zigbee" } },
          en: { title: "SMLIGHT SLZB", description: "SLZB-06/07/MR Zigbee coordinators: temperature, memory, network, mode and firmware version, with new firmware alerts.",
                points: { esp_temp: "ESP temperature", zb_temp: "Zigbee temperature", ram: "Memory used", ethernet: "Ethernet cable",
                          mode: "Coordinator mode", core: "Core firmware", zigbee: "Zigbee firmware" } },
          es: { title: "SMLIGHT SLZB", description: "Coordinadores Zigbee SLZB-06/07/MR: temperatura, memoria, red, modo y versión del firmware, con aviso de firmware nuevo.",
                points: { esp_temp: "Temperatura del ESP", zb_temp: "Temperatura del Zigbee", ram: "Memoria usada", ethernet: "Cable de red",
                          mode: "Modo del coordinador", core: "Firmware del núcleo", zigbee: "Firmware del Zigbee" } }
    field :host, required: true
    mdns "_slzb-06._tcp"
    dhcp({ hostname: "slzb-*" })

    class << self
      def get(host, path)
        res = Net::HTTP.start(host, 80, open_timeout: 5, read_timeout: 10) { |h| h.get(path) }
        raise Integrations::Error, "SLZB: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)
      rescue *LanPlugin::NET_ERRORS, JSON::ParserError => e
        raise Integrations::Error, "SLZB: #{e.class.name.demodulize}"
      end

      def info(host) = get(host, "/ha_info")["Info"].to_h

      def entries(integration)
        host = conf(integration, :host)
        i = info(host)
        [ entry(id: "smlight:#{i['MAC'].presence || host}", name: i["model"].presence || title, model: i["model"], firmware: i["sw_version"], poll_s: 120,
                address: { "host" => host },
                points: [ point("esp_temp", unit: "°C", device_class: "temperature", state_class: "measurement"),
                          point("zb_temp", unit: "°C", device_class: "temperature", state_class: "measurement"),
                          point("ram", unit: "KB", state_class: "measurement"), point("uptime", unit: "s", state_class: "measurement"),
                          point("ethernet", "contact", device_class: "connectivity"), point("mode", "text", writable: false),
                          point("core", "text", writable: false), point("zigbee", "text", writable: false) ]) ]
      end

      def read(device)
        host = device.address["host"]
        s = get(host, "/ha_sensors")["Sensors"].to_h
        i = info(host)
        device.update_columns(firmware: i["sw_version"]) if i["sw_version"].present? && device.firmware != i["sw_version"]
        { "esp_temp" => s["esp32_temp"], "zb_temp" => s["zb_temp"], "ram" => s["ram_usage"], "uptime" => s["uptime"], "ethernet" => s["ethernet"],
          "mode" => { 0 => "Ethernet", 1 => "Wi-Fi", 2 => "USB" }.fetch(i["coord_mode"].to_i, i["coord_mode"].to_s), "core" => i["sw_version"], "zigbee" => i["zb_version"] }
      end
    end
  end
end
