module Recordings
  # Gravação contínua (ondaC2, C10) no processo worker, no padrão do
  # Onvif::Listener: uma thread por câmera em "continuous", gravando trechos
  # de SEGMENT_S um atrás do outro. Câmera saiu do modo: a thread termina no
  # fim do trecho. Erro: espera crescente (até 60 s). RECORDINGS=off desliga.
  class Recorder
    SCAN_EVERY = 60
    MAX_BACKOFF = 60

    @threads = Concurrent::Map.new

    class << self
      def start
        return if @supervisor&.alive? || Drivers::Go2rtc.url.nil?

        @supervisor = Thread.new do
          loop do
            scan
            sleep SCAN_EVERY
          end
        end
      end

      def wanted
        Rails.application.executor.wrap do
          ActsAsTenant.without_tenant { Recordings.cameras.to_a.select { |p| Recordings.settings(p)["mode"] == "continuous" }.map(&:id) }
        end
      end

      def scan
        wanted.each { |id| @threads[id] = Thread.new { run(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      # Grava enquanto a câmera seguir em "continuous". `rounds` limita o laço (specs).
      def run(point_id, rounds: nil)
        failures = 0
        n = 0
        until rounds && (n += 1) > rounds
          ok = Rails.application.executor.wrap do
            point = ActsAsTenant.without_tenant { Point.find_by(id: point_id) }
            next :stop unless point && !point.disabled && Recordings.settings(point)["mode"] == "continuous"

            ActsAsTenant.with_tenant(point.tenant) { Recordings.record!(point, SEGMENT_S, "continuous") }
            true
          rescue Recordings::Error => e
            Rails.logger.warn("[gravacao] #{point_id}: #{e.message}")
            false
          end
          break if ok == :stop

          failures = ok ? 0 : failures + 1
          sleep [ 2**failures, MAX_BACKOFF ].min unless ok
        end
      end
    end
  end
end
