module Drivers
  # Echo da Alexa: anúncio (`announce`, com o som de aviso), fala (`speak`) e
  # rotina da conta (`routine`, valor = nome) pelo `Alexa::Client`; sessão
  # vencida renova sozinha pelo Alexa::Auth quando a conta entrou pelo login. A conta (cookies) fica na integração do aparelho;
  # `external_id` = número de série, `address` {device_type, customer_id}.
  # Sucesso ou erro vão para o estado da integração (tela de integrações).
  class Alexa
    class Error < StandardError; end

    # Comando do ponto `speaker` → chamada no cliente (valor = texto ou nome da rotina).
    ACTIONS = {
      "announce" => ->(client, target, text) { client.announce([ target ], text) },
      "speak" => ->(client, target, text) { client.speak(target, text) },
      "routine" => ->(client, target, name) { client.run_routine(target, name) },
      # G12 (Lote 8): som, música e volume.
      "sound" => ->(client, target, id) { client.sound(target, id) },
      "play" => ->(client, target, phrase) { client.play(target, phrase) },
      "volume" => ->(client, target, level) { client.volume(target, level) },
      # G12: ponto `media` (tocar/pausar/próxima/anterior, tocar busca) e "não perturbe" (onoff).
      "resume" => ->(client, target, _) { client.player_command(target, "resume") },
      "pause" => ->(client, target, _) { client.player_command(target, "pause") },
      "next" => ->(client, target, _) { client.player_command(target, "next") },
      "previous" => ->(client, target, _) { client.player_command(target, "previous") },
      "play_media" => ->(client, target, phrase) { client.play(target, phrase) },
      "on" => ->(client, target, _) { client.dnd(target, true) },
      "off" => ->(client, target, _) { client.dnd(target, false) }
    }.freeze

    def self.client_for(integration)
      raise Error, "Echo sem integração da Alexa." unless integration&.driver == "alexa"

      renew = (-> { ::Alexa::Auth.refresh!(integration) } if ::Alexa::Auth.refreshable?(integration))
      ::Alexa::Client.new(cookies: ::Alexa::Auth.cookies(integration), host: integration.settings["host"], renew: renew, throttle: integration.id)
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
      ACTIONS.fetch(command).call(client, target, text)
      point.report!(command == "on") if point.capability == "onoff" # "não perturbe": a Amazon não manda o eco
      integration&.ok!
    rescue ::Alexa::Client::Error => e
      integration&.error!(e.message) unless Transient.retryable?(e) # recusa passageira não é conta com erro
      raise
    end

    # Anúncio numa chamada só para várias Echo da mesma conta (lote do
    # ExecuteCommandJob; docs/confiabilidade.md). Outros comandos: um por Echo.
    def execute_group(points, command, value)
      return points.each { |p| execute(p, command, value) } unless command == "announce"

      text = Points::Command.new(points.first, command, value).tap(&:new_value).value
      integration = points.first.device.integration
      client = @client || self.class.client_for(integration)
      client.announce(points.map { |p| self.class.target(p.device) }, text)
      integration&.ok!
    rescue ::Alexa::Client::Error => e
      integration&.error!(e.message) unless Transient.retryable?(e)
      raise
    end
  end
end
