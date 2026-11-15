require "net/http"

module Cameras
  # Câmeras pré-carregadas (mobile-ajustes, 15/11/2026): no processo worker, uma thread por câmera da rede
  # de casa segura um consumidor no go2rtc (`/api/stream.mp4`, lido e descartado). Com o RTSP já aberto,
  # o quadro e o ao vivo não esperam a conexão com o DVR: medido na casa, o primeiro quadro das câmeras
  # mais lentas caiu de ~4,2 s para ~1 s. Custo: o substream de cada câmera correndo o tempo todo dentro
  # do compose (~100 kbps por câmera no DVR da casa).
  #
  # Fica de fora: câmera de nuvem (`on_demand`: o link é assinado e cobrado por sessão), MQTT e a que está
  # na espera de falha do go2rtc. A lista é refeita a cada SCAN_EVERY; câmera que caiu tenta de novo com
  # espera crescente (até MAX_BACKOFF). CAMERA_PRELOAD=off desliga (config/initializers/tuya_listener.rb).
  class Warmer
    SCAN_EVERY = 60
    MAX_BACKOFF = 120
    READ_TIMEOUT = 30

    @threads = Concurrent::Map.new

    class << self
      def start
        return unless Drivers::Go2rtc.url
        return if @supervisor&.alive?

        @supervisor = Thread.new do
          loop do
            scan
            sleep SCAN_EVERY
          end
        end
      end

      def wanted
        Rails.application.executor.wrap do
          ActsAsTenant.without_tenant do
            Drivers::Go2rtc.points.to_a.select { |p| p.address["on_demand"].blank? && p.address["image"] != "mqtt" && Drivers::Go2rtc.source(p) }.map(&:id)
          end
        end
      end

      def scan
        ids = wanted
        (@threads.keys - ids).each { |id| @threads.delete(id)&.kill }
        ids.each { |id| @threads[id] = Thread.new { hold(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def hold(id)
        failures = 0
        loop do
          failures = consume(id) ? 0 : failures + 1
          sleep [ 2**[ failures, 7 ].min, MAX_BACKOFF ].min
        end
      end

      # Uma conexão: true se chegou vídeo (o go2rtc abriu o RTSP). `limit` (bytes) encerra antes (specs).
      def consume(id, limit: nil)
        uri = URI.join(Drivers::Go2rtc.url, "/api/stream.mp4")
        uri.query = URI.encode_www_form(src: id)
        got = 0
        Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: READ_TIMEOUT) do |http|
          http.request(Net::HTTP::Get.new(uri)) do |res|
            return false unless res.is_a?(Net::HTTPSuccess)

            res.read_body do |chunk|
              got += chunk.bytesize
              return true if limit && got >= limit
            end
          end
        end
        got.positive?
      rescue SystemCallError, SocketError, Timeout::Error, IOError, Net::HTTPBadResponse => e
        Rails.logger.info("[câmeras] pré-carga #{id}: #{e.class.name.demodulize}")
        got.positive?
      end

      def running = @threads.keys
    end
  end
end
