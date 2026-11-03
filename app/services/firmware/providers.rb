module Firmware
  # Provedores que vêm com o produto.
  module Providers
    # Shelly Gen2 (RPC Shelly.CheckForUpdate/Shelly.Update) e Gen1 (/status e /ota).
    class Shelly < Provider
      describe key: "shelly"

      def self.handles?(device) = device.driver == "shelly"

      def self.check(device)
        conn = Drivers::Shelly.conn(device)
        if conn["gen"].to_i >= 2
          ver = ::Shelly.rpc(conn, "Shelly.GetDeviceInfo")["ver"]
          { installed: ver, latest: ::Shelly.rpc(conn, "Shelly.CheckForUpdate").dig("stable", "version") || ver }
        else
          u = ::Shelly.get(conn, "/status")["update"].to_h
          { installed: u["old_version"], latest: u["has_update"] ? u["new_version"] : u["old_version"] }
        end
      end

      def self.install!(device)
        conn = Drivers::Shelly.conn(device)
        conn["gen"].to_i >= 2 ? ::Shelly.rpc(conn, "Shelly.Update", { stage: "stable" }) : ::Shelly.get(conn, "/ota?update=true")
      end
    end

    # Zigbee2MQTT: o próprio Z2M publica `update` no estado do aparelho (o ponto
    # lê pelo json_path); instalar é o pedido ota_update/update da ponte.
    class Zigbee2mqtt < Provider
      describe key: "zigbee2mqtt"

      def self.handles?(device) = device.driver == "mqtt" && device.points.any? { |p| p.capability == "update" && p.address["json_path"] == "update" }

      def self.install!(device)
        topic = device.points.find { |p| p.capability == "update" }.address["topic"].to_s
        base = topic.delete_suffix("/#{device.name}")
        Mqtt::Listener.publish("#{base}/bridge/request/device/ota_update/update", { id: device.external_id }.to_json)
      end
    end

    # ondaC1 (C1): Z-Wave JS pergunta ao serviço de firmware do Z-Wave JS
    # (`controller.get_available_firmware_updates`) e instala pelo ar
    # (`controller.firmware_update_ota`), como o HA.
    class ZwaveJs < Provider
      describe key: "zwave_js"

      def self.handles?(device) = device.driver == "zwave_js" && device.integration.present?

      def self.check(device)
        with(device) do |c, node|
          latest = c.firmware_updates(node["nodeId"]).max_by { |u| Gem::Version.new(u["version"].to_s) rescue Gem::Version.new("0") } # rubocop:disable Style/RescueModifier
          { installed: node["firmwareVersion"], latest: latest&.dig("version") || node["firmwareVersion"], notes_url: nil }
        end
      end

      def self.install!(device)
        with(device) do |c, node|
          update = c.firmware_updates(node["nodeId"]).max_by { |u| Gem::Version.new(u["version"].to_s) rescue Gem::Version.new("0") } or # rubocop:disable Style/RescueModifier
            raise Integrations::Error, I18n.t("firmware.no_update")
          c.firmware_update!(node["nodeId"], update)
        end
      end

      def self.with(device)
        ::ZwaveJs::Client.open(device.integration.settings["url"]) do |c|
          node = Array(c.state["nodes"]).find { |n| n["nodeId"].to_s == device.address["node"].to_s } or raise Integrations::Error, I18n.t("firmware.no_provider")
          yield c, node
        end
      rescue ::ZwaveJs::Error => e
        raise Integrations::Error, e.message
      end
    end

    # ondaC1 (C3): Matter pelo python-matter-server, que consulta a DCL (o
    # registro oficial de firmware do Matter): `check_node_update` e `update_node`.
    class Matter < Provider
      describe key: "matter"
      VERSION = "0/40/10" # Basic Information → SoftwareVersionString

      def self.handles?(device) = device.driver == "matter" && device.integration.present?

      def self.check(device)
        with(device) do |c, node_id|
          node = Array(c.nodes).find { |n| n["node_id"].to_s == node_id.to_s }
          installed = node&.dig("attributes", VERSION)
          up = c.call("check_node_update", { "node_id" => node_id })
          { installed: installed, latest: up&.dig("software_version_string") || installed, notes_url: up&.dig("release_notes_url") }
        end
      end

      def self.install!(device)
        with(device) do |c, node_id|
          up = c.call("check_node_update", { "node_id" => node_id }) or raise Integrations::Error, I18n.t("firmware.no_update")
          c.call("update_node", { "node_id" => node_id, "software_version" => up["software_version"] }, timeout: ::Matter::Client::COMMISSION_TIMEOUT)
        end
      end

      def self.with(device)
        ::Matter::Client.open(device.integration.settings["url"]) { |c| yield c, device.address["node"] || device.external_id.to_i }
      rescue ::Matter::Client::Error => e
        raise Integrations::Error, e.message
      end
    end

    # resto: aparelho da descoberta MQTT do HA com componente `update`: ele
    # mesmo informa as versões; instalar = publicar o `payload_install`.
    class Mqtt < Provider
      describe key: "mqtt"

      def self.point(device) = device.points.find { |p| p.capability == "update" && p.address["payload_install"] }
      def self.handles?(device) = device.driver == "mqtt" && point(device).present?

      def self.install!(device)
        a = point(device).address
        ::Mqtt::Listener.publish(a["command_topic"], a["payload_install"].to_s)
      end
    end

    # resto: Tasmota (descoberta nativa, versão no `sw`): a mais nova vem das
    # versões publicadas do Tasmota; instalar = `Upgrade 1` (baixa do OtaUrl do aparelho).
    class Tasmota < Provider
      describe key: "tasmota"
      RELEASES = "https://api.github.com/repos/arendst/Tasmota/releases/latest".freeze

      def self.handles?(device) = device.driver == "mqtt" && device.manufacturer == "Tasmota" && device.address["cmnd"].present?

      def self.latest
        Rails.cache.fetch("firmware/tasmota/latest", expires_in: 6.hours) do
          JSON.parse(SafeHttp.get(RELEASES, timeout: 10).body)["tag_name"].to_s.delete_prefix("v").presence
        end
      rescue SafeHttp::Error, JSON::ParserError => e
        raise Integrations::Error, e.message
      end

      def self.check(device)
        installed = device.firmware.to_s[/\d+(\.\d+)+/] or return nil
        { installed: installed, latest: latest || installed, notes_url: "https://github.com/arendst/Tasmota/releases" }
      end

      def self.install!(device) = ::Mqtt::Listener.publish("#{device.address['cmnd']}Upgrade", "1")
    end

    # resto: ESPHome pelo painel do app ESPHome (ESPHOME_DASHBOARD_URL): a
    # versão nova é a do painel; instalar = compilar e mandar pelo ar
    # (`/upload`), numa thread que acompanha o processo até o fim (o painel
    # para a compilação se o websocket fechar).
    class Esphome < Provider
      describe key: "esphome"
      UPLOAD_TIMEOUT = 15 * 60

      def self.url = ENV["ESPHOME_DASHBOARD_URL"].presence
      def self.handles?(device) = device.driver == "esphome" && url.present?

      def self.entry(device)
        res = Net::HTTP.get_response(URI("#{url}/devices"))
        raise Integrations::Error, "ESPHome: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        host = device.address["host"].to_s
        Array(JSON.parse(res.body)["configured"]).find { |d| [ d["address"], "#{d['name']}.local" ].include?(host) || d["name"] == device.name.parameterize }
      rescue *Integrations::LanPlugin::NET_ERRORS, JSON::ParserError => e
        raise Integrations::Error, "ESPHome: #{e.message}"
      end

      def self.check(device)
        e = entry(device) or return nil
        { installed: e["deployed_version"] || device.firmware, latest: e["current_version"], notes_url: "https://esphome.io/changelog/" }
      end

      def self.install!(device)
        conf = entry(device)&.dig("configuration") or raise Integrations::Error, I18n.t("firmware.no_update")
        Thread.new { Rails.application.executor.wrap { upload(conf, device.id) } }
      end

      def self.upload(conf, device_id)
        WsClient.open("#{url.sub(/\Ahttp/, 'ws')}/upload", timeout: UPLOAD_TIMEOUT) do |ws|
          ws.send_json(type: "spawn", configuration: conf, port: "OTA")
          while (m = ws.read_json(UPLOAD_TIMEOUT))
            next unless m["event"] == "exit"

            Rails.logger.info("[firmware] ESPHome #{conf}: saiu com #{m['code']}")
            return m["code"].to_i.zero?
          end
        end
      rescue WsClient::Error => e
        Rails.logger.warn("[firmware] ESPHome #{conf} (#{device_id}): #{e.message}")
        false
      end
    end
  end
end
