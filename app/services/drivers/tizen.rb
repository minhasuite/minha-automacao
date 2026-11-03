module Drivers
  # Samsung Tizen (Pacote 1): teclas do controle pelo canal
  # `samsung.remote.control` (WebSocket wss na 8002; ws na 8001). Na primeira
  # vez a TV pede para permitir; o token que volta fica cifrado na
  # integração. Estado por `GET http://tv:8001/api/v2/` (PowerState). Sem
  # volume exato: só sobe, desce e mudo. Ligar só por Wake-on-LAN.
  class Tizen < MediaLan
    PORT = 8002
    INFO_PORT = 8001
    KEYS = { "off" => "KEY_POWER", "volume_up" => "KEY_VOLUP", "volume_down" => "KEY_VOLDOWN", "mute" => "KEY_MUTE",
             "resume" => "KEY_PLAY", "pause" => "KEY_PAUSE", "next" => "KEY_FF", "previous" => "KEY_REWIND" }.freeze
    SUPPORTS = (KEYS.keys + %w[play_media]).freeze
    NAME = Base64.strict_encode64("Minha Automação")
    # ondaC2 (C9): tocar endereço = abrir no navegador da TV (a TV Samsung também é reprodutor DLNA: DlnaPlugin toca direto).
    BROWSER = { "appId" => "org.tizen.browser", "action_type" => "NATIVE_LAUNCH" }.freeze

    class << self
      def off_when_unreachable? = true

      def info(host)
        res = Net::HTTP.start(host, INFO_PORT, open_timeout: 3, read_timeout: 3) { |h| h.get("/api/v2/") }
        raise self::Error, "A TV respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)["device"] || {}
      end

      def read(device)
        power = info(host(device))["PowerState"]
        { "state" => power.nil? || power == "on" ? "on" : "off" }
      end

      def run(device, command, value)
        return wake!(device.address["mac"]) if command == "on"

        remote(secrets_owner(device), host(device), port(device, PORT)) do |ws|
          next ws.send_json("method" => "ms.channel.emit", "params" => { "event" => "ed.apps.launch", "to" => "host", "data" => BROWSER.merge("metaTag" => value.to_s) }) if command == "play_media"

          ws.send_json("method" => "ms.remote.control",
                       "params" => { "Cmd" => "Click", "DataOfCmd" => KEYS.fetch(command), "Option" => "false", "TypeOfRemote" => "SendRemoteKey" })
        end
      end

      # Canal do controle. A primeira mensagem diz se entrou (e traz o token) ou se a TV recusou.
      def remote(integration, host, port, timeout: 5)
        token = integration.secrets["token"]
        url = "#{port.to_i == INFO_PORT ? 'ws' : 'wss'}://#{host}:#{port}/api/v2/channels/samsung.remote.control?name=#{CGI.escape(NAME)}#{"&token=#{CGI.escape(token)}" if token.present?}"
        WsClient.open(url, timeout: timeout) do |ws|
          m = ws.read_json(timeout) or raise self::Error, "A TV não respondeu. Permita o acesso na tela da TV e tente de novo."
          raise Integrations.auth(self::Error.new("A TV recusou o acesso. Permita na tela da TV e tente de novo.")) if m["event"] == "ms.channel.unauthorized"

          fresh = m.dig("data", "token")
          integration.merge_secrets!("token" => fresh) if fresh.present? && fresh != token
          yield ws
        end
      end
    end
  end
end
