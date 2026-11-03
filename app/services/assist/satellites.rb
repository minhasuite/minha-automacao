module Assist
  # Satélites de voz (ondaB1, B6; o Voice PE, o ESPHome e o
  # wyoming-satellite do HA): aparelho com microfone numa área, ligado a um
  # pipeline. Cada tipo é um plugin; o Listener (no worker) mantém uma conexão
  # por satélite ligado e, a cada pedido, roda o Assist::Pipeline com a área
  # do satélite ("acenda a luz" sem dizer o cômodo) e o papel dele.
  #   describe key:, label:, hint:, needs: %i[host] | %i[device]
  #   serve(satellite, rounds: nil) — uma conexão (laço até cair)
  module Satellites
    PLUGINS = %w[WyomingSatellite EsphomeSatellite].freeze

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |p| p.key == key.to_s }

    # Fim da fala (VAD simples por volume): falou e ficou SILENCE s quieto, ou passou MAX s.
    # ponytail: limiar fixo por ENV; calibrar por satélite se o ruído da casa pedir.
    class Vad
      SILENCE = 0.8
      MAX = 10
      MIN_SPEECH = 0.3

      def initialize(rate: Wyoming::RATE, width: Wyoming::WIDTH, channels: Wyoming::CHANNELS, threshold: ENV.fetch("ASSIST_VAD_RMS", 450).to_i)
        @bps = rate * width * channels
        @threshold = threshold
        @speech = 0.0
        @silence = 0.0
        @total = 0.0
      end

      # Mais um trecho PCM → true quando a fala acabou.
      def push(pcm)
        sec = pcm.bytesize.to_f / @bps
        @total += sec
        if Wyoming.rms(pcm) >= @threshold
          @speech += sec
          @silence = 0
        else
          @silence += sec
        end
        @total >= MAX || (@speech >= MIN_SPEECH && @silence >= SILENCE)
      end
    end

    class Base
      extend PluginTexts
      translates :label, :hint

      class << self
        attr_reader :key, :needs

        def describe(key:, label:, needs:, hint: nil)
          @key = key
          @label = label
          @needs = needs
          @hint = hint
        end

        def serve(_satellite, rounds: nil) = raise(NotImplementedError)

        # Um pedido falado (WAV 16 kHz) → resposta do pipeline (com os bytes da fala).
        def run(satellite, wav)
          Pipeline.run(site: satellite.site, user: nil, audio: wav, media_type: "audio/wav", speak: true, satellite: satellite, source: "satellite", keep_audio: true)
        end
      end
    end

    # Mantém uma thread por satélite ligado no worker (padrão do Esphome::Listener).
    class Listener
      SCAN_EVERY = 60
      MAX_BACKOFF = 60

      @threads = Concurrent::Map.new

      class << self
        def start
          return if @supervisor&.alive?

          @supervisor = Thread.new do
            loop do
              scan
              sleep SCAN_EVERY
            end
          end
        end

        def scan
          wanted = Rails.application.executor.wrap { ActsAsTenant.without_tenant { AssistSatellite.where(enabled: true).pluck(:id) } }
          (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill }
          wanted.each { |id| @threads[id] = Thread.new { listen(id) } unless @threads[id]&.alive? }
        rescue StandardError => e
          Rails.error.report(e, handled: true)
        end

        def listen(id)
          failures = 0
          loop do
            failures = run_once(id) ? 0 : failures + 1
            sleep [ 2**failures, MAX_BACKOFF ].min
          end
        end

        def run_once(id, rounds: nil)
          with(id) { |sat| Satellites[sat.kind]&.serve(sat, rounds: rounds) }
          true
        rescue StandardError => e
          Rails.logger.warn("[satellite] #{id}: #{e.message}")
          with(id) { |sat| sat.update_columns(last_error: e.message.truncate(200)) }
          false
        end

        def with(id)
          Rails.application.executor.wrap do
            sat = ActsAsTenant.without_tenant { AssistSatellite.find_by(id: id) }
            sat && ActsAsTenant.with_tenant(sat.tenant) { yield sat }
          end
        end
      end
    end
  end
end
