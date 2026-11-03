module Assist
  module Satellites
    # Satélite ESPHome (Voice PE, ESP32-S3 com `voice_assistant:`), pela API
    # nativa do aparelho já integrado (Esphome::Client, com a chave dele): o
    # MA assina o assistente de voz com áudio pela própria API, recebe o
    # pedido (VoiceAssistantRequest), o áudio (VoiceAssistantAudio, 16 kHz)
    # até o fim (flag `end` ou VAD) e responde os eventos do pipeline (STT,
    # intenção, TTS com a URL da fala que o aparelho toca).
    class EsphomeSatellite < Base
      SUBSCRIBE, REQUEST, RESPONSE, EVENT, AUDIO = 89, 90, 91, 92, 106
      API_AUDIO = 1
      EVENTS = { error: 0, run_start: 1, run_end: 2, stt_start: 3, stt_end: 4, intent_start: 5, intent_end: 6, tts_start: 7, tts_end: 8,
                 stt_vad_start: 11, stt_vad_end: 12 }.freeze
      IDLE = 30

      describe key: "esphome", label: "Satélite ESPHome (Voice PE)", needs: %i[device],
               hint: "Aparelho ESPHome já integrado com voice_assistant (Home Assistant Voice PE, ESP32-S3). A fala volta por URL: o aparelho precisa alcançar este servidor."
      texts en: { label: "ESPHome satellite (Voice PE)",
                  hint: "ESPHome device already integrated with voice_assistant (Home Assistant Voice PE, ESP32-S3). Speech comes back as a URL: the device must reach this server." },
            es: { label: "Satélite ESPHome (Voice PE)",
                  hint: "Aparato ESPHome ya integrado con voice_assistant (Home Assistant Voice PE, ESP32-S3). La voz vuelve por URL: el aparato debe llegar a este servidor." }

      def self.serve(sat, rounds: nil, client: nil)
        client ||= ::Esphome.client_for(sat.device).connect
        client.send_message(SUBSCRIBE, [ [ 1, :bool, true ], [ 2, :varint, API_AUDIO ] ])
        sat.seen!
        session = Session.new(sat, client)
        n = 0
        until rounds && (n += 1) > rounds
          type, f = client.read(IDLE)
          next client.send_message(::Esphome::Client::PING_REQ) unless type

          session.handle(type, f)
        end
      ensure
        client&.close
      end

      # URL que o aparelho alcança para tocar a fala (APP_HOST na rede da casa ou ASSIST_MEDIA_URL).
      def self.media_url(path) = "#{ENV['ASSIST_MEDIA_URL'].presence || "http://#{ENV.fetch('APP_HOST', 'localhost')}"}#{path}"

      class Session
        def initialize(sat, client)
          @sat = sat
          @client = client
          @active = false
        end

        def handle(type, f)
          case type
          when REQUEST then f[1]&.first.to_i == 1 ? start(f) : (@active = false)
          when AUDIO then audio(Array(f[1]).first.to_s.b, f[2]&.first.to_i == 1) if @active
          end
        end

        private

        def start(f)
          @conversation = ::Proto.string(f[2]&.first).presence
          @active = true
          @pcm = "".b
          @vad = Vad.new
          @client.send_message(RESPONSE, [ [ 1, :varint, 0 ], [ 2, :bool, false ] ])
          event(:run_start)
          event(:stt_start)
        end

        def audio(data, last)
          @pcm << data
          finish if last || @vad.push(data)
        end

        def finish
          @active = false
          event(:stt_vad_end)
          out = EsphomeSatellite.run(@sat, ::Wyoming.wav(@pcm, ::Wyoming::RATE, ::Wyoming::WIDTH, ::Wyoming::CHANNELS))
          event(:stt_end, "text" => out["heard"])
          event(:intent_start)
          event(:intent_end, "conversation_id" => out["conversation_id"].to_s)
          if out["audio_url"]
            event(:tts_start, "text" => out["text"])
            event(:tts_end, "url" => EsphomeSatellite.media_url(out["audio_url"]))
          end
          event(:run_end)
        rescue Ai::Client::Error, ArgumentError => e
          event(:error, "code" => "pipeline", "message" => e.message.truncate(200))
          event(:run_end)
        end

        def event(name, data = {})
          fields = [ [ 1, :enum, EVENTS.fetch(name) ] ] + data.map { |k, v| [ 2, :message, ::Proto.encode([ [ 1, :string, k ], [ 2, :string, v.to_s ] ]) ] }
          @client.send_message(EVENT, fields)
        end
      end
    end
  end
end
