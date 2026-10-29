module Drivers
  # Echo da Alexa: anúncio (`announce`, com o som de aviso) e fala (`speak`)
  # pelo `Alexa::Client`. A conta (cookies) fica na integração do aparelho;
  # `external_id` = número de série, `address` {device_type, customer_id}.
  # Sucesso ou erro vão para o estado da integração (tela de integrações).
  class Alexa
    class Error < StandardError; end

    def self.client_for(integration)
      raise Error, "Echo sem integração da Alexa." unless integration&.driver == "alexa"

      ::Alexa::Client.new(cookies: integration.secrets, host: integration.settings["host"])
    end

    def self.target(device)
      { serial: device.external_id, type: device.address["device_type"], customer_id: device.address["customer_id"] }
    end

    def initialize(client: nil)
      @client = client
    end

    def execute(point, command, value)
      text = Points::Command.new(point, command, value).tap(&:new_value).value
      integration = point.device.integration
      client = @client || self.class.client_for(integration)
      target = self.class.target(point.device)
      command == "speak" ? client.speak(target, text) : client.announce([ target ], text)
      integration&.ok!
    rescue ::Alexa::Client::Error => e
      integration&.error!(e.message)
      raise
    end
  end
end
