module Drivers
  # LG webOS (Pacote 1): WebSocket na porta 3000 (3001 = wss) com o
  # protocolo SSAP. Na primeira vez a TV mostra o pedido de pareamento; o
  # client-key que volta fica cifrado na integração e as próximas sessões
  # entram direto. Ligar só por Wake-on-LAN (MAC lido na varredura).
  class Webos < MediaLan
    PORT = 3000
    SUPPORTS = %w[off resume pause next previous volume volume_up volume_down mute play_media].freeze
    MANIFEST = { "manifestVersion" => 1, "appVersion" => "1.1",
                 "permissions" => %w[LAUNCH LAUNCH_WEBAPP APP_TO_APP CONTROL_AUDIO CONTROL_DISPLAY CONTROL_INPUT_MEDIA_PLAYBACK CONTROL_POWER
                                     READ_INSTALLED_APPS READ_RUNNING_APPS READ_CURRENT_CHANNEL READ_NETWORK_STATE READ_TV_CURRENT_TIME] }.freeze
    CALLS = { "off" => "ssap://system/turnOff", "volume_up" => "ssap://audio/volumeUp", "volume_down" => "ssap://audio/volumeDown",
              "resume" => "ssap://media.controls/play", "pause" => "ssap://media.controls/pause",
              "next" => "ssap://media.controls/fastForward", "previous" => "ssap://media.controls/rewind" }.freeze

    class << self
      def off_when_unreachable? = true
      def url(host, port) = "#{port.to_i == 3001 ? 'wss' : 'ws'}://#{host}:#{port}"

      # Sessão registrada. `pair_timeout`: quanto esperar a pessoa aceitar na TV.
      def session(integration, host, port, pair_timeout: 5)
        WsClient.open(url(host, port)) do |ws|
          s = Session.new(ws)
          s.register(integration, pair_timeout)
          yield s
        end
      end

      def device_session(device, &) = session(secrets_owner(device), host(device), port(device, PORT), &)

      def read(device)
        device_session(device) { |s| state(s) }
      end

      def state(s)
        vol = s.call("ssap://audio/getVolume")
        vol = vol["volumeStatus"] if vol["volumeStatus"].is_a?(Hash)
        app = s.call("ssap://com.webos.applicationManager/getForegroundAppInfo")["appId"]
        { "state" => "on", "app" => app.presence, "volume" => vol["volume"], "muted" => vol.key?("muted") ? vol["muted"] : vol["muteStatus"] }.compact
      end

      def run(device, command, value)
        return wake!(device.address["mac"]) if command == "on"

        device_session(device) do |s|
          case command
          when "volume" then s.call("ssap://audio/setVolume", "volume" => value)
          when "mute" then s.call("ssap://audio/setMute", "mute" => value)
          when "play_media" then s.call("ssap://system.launcher/open", "target" => value)
          else s.call(CALLS.fetch(command))
          end
        end
      end
    end

    class Session
      def initialize(ws)
        @ws = ws
        @n = 0
      end

      def register(integration, timeout)
        key = integration.secrets["client_key"]
        payload = { "forcePairing" => false, "pairingType" => "PROMPT", "client-key" => key, "manifest" => MANIFEST }.compact
        @ws.send_json("type" => "register", "id" => "register_0", "payload" => payload)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          m = (@ws.read_json(left) if left.positive?) or
            raise Webos::Error, "A TV não confirmou o pareamento. Aceite o pedido na tela da TV e tente de novo."
          raise Webos::Error, "A TV recusou: #{m['error']}" if m["type"] == "error"
          next unless m["type"] == "registered"

          fresh = m.dig("payload", "client-key")
          integration.merge_secrets!("client_key" => fresh) if fresh.present? && fresh != key
          return
        end
      end

      def call(uri, payload = nil)
        id = "r#{@n += 1}"
        @ws.send_json({ "type" => "request", "id" => id, "uri" => uri, "payload" => payload }.compact)
        loop do
          m = @ws.read_json or raise Webos::Error, "A TV não respondeu a #{uri}."
          next unless m["id"] == id
          raise Webos::Error, "A TV recusou #{uri}: #{m['error']}" if m["type"] == "error" || m.dig("payload", "returnValue") == false

          return m["payload"] || {}
        end
      end
    end
  end
end
