module Assist
  module Satellites
    # wyoming-satellite (Raspberry Pi com microfone, como no HA): o MA conecta
    # na porta do satélite (10700), manda "run-satellite" e, a cada
    # "run-pipeline", ouve o áudio. Começando na palavra de ativação, o áudio
    # passa pelo motor `wake` do pipeline até a detecção; depois, até o fim
    # da fala (VAD), vira WAV para o STT. Volta "transcript", "synthesize" e a
    # fala em PCM (audio-start/chunk/stop) quando o TTS gera WAV.
    class WyomingSatellite < Base
      IDLE = 30

      describe key: "wyoming", label: "Satélite Wyoming (wyoming-satellite)", needs: %i[host],
               hint: "Raspberry Pi ou similar com wyoming-satellite (porta padrão 10700). A palavra de ativação pode ser do satélite ou do pipeline."
      texts en: { label: "Wyoming satellite (wyoming-satellite)",
                  hint: "Raspberry Pi or similar running wyoming-satellite (default port 10700). The wake word can run on the satellite or in the pipeline." },
            es: { label: "Satélite Wyoming (wyoming-satellite)",
                  hint: "Raspberry Pi o similar con wyoming-satellite (puerto por defecto 10700). La palabra de activación puede ser del satélite o del pipeline." }

      def self.serve(sat, rounds: nil)
        ::Wyoming.open(sat.host, sat.port.presence || ::Wyoming::PORTS[:satellite], timeout: 10) do |c|
          c.write("describe")
          c.until("info")
          c.write("run-satellite")
          sat.seen!
          session = Session.new(sat, c)
          n = 0
          until rounds && (n += 1) > rounds
            event = c.read(IDLE)
            next c.write("ping") unless event

            sat.seen!
            session.handle(*event)
          end
        ensure
          session&.close
        end
      end

      # Estado de um pedido falado do satélite.
      class Session
        def initialize(sat, conn)
          @sat = sat
          @conn = conn
          @active = false
        end

        def handle(type, data, payload)
          case type
          when "run-pipeline" then start(data)
          when "audio-start" then @fmt = data
          when "audio-chunk" then chunk(payload.to_s) if @active
          when "audio-stop" then finish if @active
          when "ping" then @conn.write("pong")
          end
        end

        def close = @wake&.close

        private

        def start(data)
          @active = true
          @pcm = "".b
          @vad = Vad.new
          engine = @sat.pipeline_or_default&.engine(:wake)
          @wake = data["start_stage"] == "wake" && engine.is_a?(Class) && engine <= Engines::WyomingServer ? wake_stream(@sat.pipeline_or_default.wake) : nil
        end

        def chunk(pcm)
          return wake_chunk(pcm) if @wake

          @pcm << pcm
          finish if @vad.push(pcm)
        end

        # Palavra de ativação no servidor do pipeline: o áudio vai em fluxo até "detection".
        def wake_stream(cfg)
          sock = Socket.tcp(cfg["host"], Engines::WyomingServer.port(cfg, :wake), connect_timeout: 5)
          conn = ::Wyoming::Connection.new(sock, 5)
          conn.write("detect", { "names" => cfg["names"].to_s.split(/[,\s]+/).compact_blank.presence }.compact)
          conn.write("audio-start", format)
          conn
        end

        def wake_chunk(pcm)
          @wake.write("audio-chunk", format, pcm)
          type, data = @wake.read(0)
          return unless type == "detection"

          @conn.write("detection", { "name" => data["name"] }.compact)
          @wake.close
          @wake = nil
        end

        def format = { "rate" => (@fmt || {})["rate"] || ::Wyoming::RATE, "width" => (@fmt || {})["width"] || ::Wyoming::WIDTH, "channels" => (@fmt || {})["channels"] || ::Wyoming::CHANNELS }

        def finish
          @active = false
          @conn.write("voice-stopped")
          f = format
          out = WyomingSatellite.run(@sat, ::Wyoming.wav(@pcm, f["rate"], f["width"], f["channels"]))
          @conn.write("transcript", { "text" => out["heard"] })
          @conn.write("synthesize", { "text" => out["text"] }) if out["text"].present?
          speak(out["audio"])
        rescue Ai::Client::Error, ArgumentError => e
          @conn.write("error", { "text" => e.message.truncate(200), "code" => "pipeline" })
        end

        def speak(voice)
          return unless voice && voice[:media_type] == "audio/wav"

          pcm, rate, width, channels = voice[:pcm] ? voice.values_at(:pcm, :rate, :width, :channels) : ::Wyoming.pcm_of(voice[:data])
          fmt = { "rate" => rate, "width" => width, "channels" => channels }
          @conn.write("audio-start", fmt)
          ::Wyoming.chunks(pcm) { |part| @conn.write("audio-chunk", fmt, part) }
          @conn.write("audio-stop")
        rescue ::Wyoming::Error => e
          Rails.logger.info("[satellite] fala não enviada: #{e.message}")
        end
      end
    end
  end
end
