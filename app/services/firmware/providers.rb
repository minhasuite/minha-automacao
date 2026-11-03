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
  end
end
