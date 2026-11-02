module Drivers
  # Midea (integ2): AC pela rede local (protocolo V3, `Midea::Session`).
  # Endereço {host, port, device_id}; token e chave ficam na integração. O
  # comando grava o estado inteiro (o AC não aceita um campo só).
  class Midea < Climate
    NET = [ ::Midea::Error, *Integrations::LanPlugin::NET_ERRORS ].freeze

    def self.vendor = "midea"

    def self.session(device_or_integration, &)
      s = device_or_integration.is_a?(Integration) ? device_or_integration.settings : device_or_integration.address
      secrets = (device_or_integration.is_a?(Integration) ? device_or_integration : device_or_integration.integration).secrets
      ::Midea::Session.open(host: s["host"], port: s["port"], device_id: s["device_id"], token: secrets["token"], key: secrets["key"], &)
    rescue *NET => e
      raise e.is_a?(Integrations::AuthError) ? Integrations.auth(Integrations::Error.new(e.message)) : Integrations::Error.new(e.message)
    end

    def self.entry(integration)
      s = integration.settings
      raise Integrations::Error, "Informe o id do aparelho (número que o msmart-ng mostra)." unless s["device_id"].to_s.match?(/\A\d+\z/)

      session(integration, &:state)
      climate_entry(id: "midea:#{s['device_id']}", name: integration.name, manufacturer: "Midea",
                    address: { "host" => s["host"], "port" => (s["port"].presence || ::Midea::PORT).to_i, "device_id" => s["device_id"] })
    end

    def self.normalize(raw)
      { "power" => raw[:power], "mode" => label("mode", raw[:mode]), "target" => raw[:target], "fan" => label("fan", raw[:fan]), "current" => raw[:current] }
    end

    def self.read(device) = normalize(session(device, &:state))

    def self.write(device, field, value)
      session(device) do |s|
        raw = s.state
        raw[:power] = value if field == "power"
        raw[:target] = value.to_f if field == "target"
        raw[:mode] = code("mode", value).to_i if field == "mode"
        raw[:fan] = code("fan", value).to_i if field == "fan"
        s.set(**raw.slice(:power, :mode, :target, :fan))
      end
    end
  end
end
