module Drivers
  # Z-Wave JS (integ2): nó do zwave-js-server; a URL do servidor fica na
  # integração. Ponto: `address` {node, cc, endpoint, property, property_key,
  # write?}. Leitura periódica pelo estado do servidor; o comando é
  # `node.set_value` e grava o pedido (o servidor confirma no próximo estado).
  class ZwaveJs
    def self.open(device, &) = ::ZwaveJs::Client.open(device.integration.settings["url"], &)

    def self.poll(device)
      open(device) do |c|
        node = Array(c.state["nodes"]).find { |n| n["nodeId"].to_s == device.address["node"].to_s } or
          raise ::ZwaveJs::Error, "Nó #{device.address['node']} não está no servidor Z-Wave JS."
        ::ZwaveJs.apply(device, node)
      end
    end

    def self.unavailable!(device) = Drivers.offline!(device)

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      raw = point.capability == "dimmer" ? v.to_i.clamp(0, 99) : v
      self.class.open(point.device) { |c| c.set_value(point.address["node"], ::ZwaveJs.value_id(point.address), raw) }
      point.report!(v)
    end
  end
end
