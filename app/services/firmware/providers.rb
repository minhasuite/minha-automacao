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
  end
end
