require "net/http"

# Eventos de movimento do DVR/NVR (23/11/2026): o gravador avisa em tempo real quando um canal vê movimento e o
# MA acende o ponto "Movimento" daquela câmera (e apaga no fim). Sem IA e sem custo: a detecção é do próprio DVR
# (no Intelbras/Dahua com a "detecção inteligente" ligada, só pessoa ou veículo; árvore, sombra e bicho não).
#
# Aparelho `go2rtc` do DVR com `address.events` = chave de um protocolo em PROTOCOLS liga o ouvinte; cada ponto
# `stream` dele com canal (pelo caminho RTSP) ganha um ponto `motion` (`address` {dvr_event: "motion", channel:}),
# na área da câmera. Protocolo novo (Hikvision ISAPI, ...) = classe com `path`, `parse(texto)` e `channel(ponto)`
# + chave em PROTOCOLS (aberto/fechado). O ouvinte roda no worker (`DvrEvents::Listener`, DVR_EVENTS=off desliga).
module DvrEvents
  # Intelbras e Dahua: `eventManager.cgi?action=attach` (multipart sem fim, Digest), uma linha por evento:
  # `Code=VideoMotion;action=Start;index=0;data={...}`. index começa em 0 (canal 1).
  module Dahua
    CODES = %w[VideoMotion SmartMotionHuman SmartMotionVehicle].freeze
    LINE = /Code=(\w+);action=(\w+);index=(\d+)/
    CHANNEL = /[?&]channel=(\d+)/

    module_function

    def path = "/cgi-bin/eventManager.cgi?action=attach&codes=%5B#{CODES.join('%2C')}%5D&heartbeat=20"

    # [[tipo, canal, ligado], ...] das linhas completas do texto (Start = true, Stop = false; Pulse = true).
    def parse(text)
      text.to_s.scan(LINE).filter_map do |code, action, index|
        next unless CODES.include?(code)

        [ "motion", index.to_i + 1, action != "Stop" ]
      end
    end

    def channel(point) = point.address["path"].to_s[CHANNEL, 1]&.to_i
  end

  PROTOCOLS = { "dahua" => Dahua }.freeze

  module_function

  def protocol(device) = PROTOCOLS[device.address["events"].to_s]

  def devices = Device.where(driver: "go2rtc", disabled: false).where("devices.address->>'events' IS NOT NULL")

  # Um ponto de movimento por câmera do DVR (idempotente). → os pontos de movimento.
  def ensure_points!(device)
    proto = protocol(device) or return []
    existing = device.points.where(capability: "motion").select { |p| p.address["dvr_event"] == "motion" }.index_by { |p| p.address["channel"].to_i }
    device.points.where(capability: "stream").order(:name).filter_map do |stream|
      ch = proto.channel(stream) or next
      existing[ch] || device.points.create!(site: device.site, area: stream.area || device.area, name: "Movimento · #{stream.name}",
                                            capability: "motion", device_class: "motion", writable: false, history: "on_change",
                                            value: false, address: { "dvr_event" => "motion", "channel" => ch })
    end
  end

  # Grava o que chegou: {canal → ligado}; sem canal (caiu) = todos indisponíveis.
  def report(device, changes, quality: "good")
    pts = device.points.where(capability: "motion").select { |p| p.address["dvr_event"] == "motion" }
    pts.each do |p|
      ch = p.address["channel"].to_i
      next unless quality != "good" || changes.key?(ch)

      value = quality == "good" ? changes[ch] : p.value
      p.report!(value, quality: quality) unless p.value == value && p.quality == quality
    end
  end

  # Uma linha por vez do fluxo do DVR, no padrão do Onvif::Listener: uma thread por aparelho, nova tentativa com
  # espera crescente (até MAX_BACKOFF); caiu = movimento indisponível até voltar.
  class Listener
    SCAN_EVERY = 60
    MAX_BACKOFF = 60
    READ_TIMEOUT = 75 # o DVR manda batimento a cada 20 s

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
        wanted = Rails.application.executor.wrap do
          ActsAsTenant.without_tenant { DvrEvents.devices.to_a.select { |d| DvrEvents.protocol(d) }.map(&:id) }
        end
        (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill }
        wanted.each { |id| @threads[id] = Thread.new { listen(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def listen(device_id)
        failures = 0
        loop do
          failures = run_once(device_id) ? 0 : failures + 1
          sleep [ 2**[ failures, 6 ].min, MAX_BACKOFF ].min
        end
      end

      # Uma conexão: true se chegou a abrir o fluxo. `limit` (eventos) encerra antes (specs).
      def run_once(device_id, limit: nil)
        cfg = nil
        with_device(device_id) do |d|
          DvrEvents.ensure_points!(d)
          cfg = { host: d.address["host"], port: (d.address["http_port"] || 80).to_i, user: d.address["username"].to_s,
                  pass: d.credential.to_s, proto: DvrEvents.protocol(d) }
        end
        return true unless cfg&.dig(:host)

        opened = false
        seen = 0
        buffer = +""
        Net::HTTP.start(cfg[:host], cfg[:port], open_timeout: 5, read_timeout: READ_TIMEOUT) do |http|
          path = cfg[:proto].path
          first = http.request(Net::HTTP::Get.new(path))
          req = Net::HTTP::Get.new(path)
          req["Authorization"] = Isapi.digest(first["www-authenticate"], cfg[:user], cfg[:pass], path) if first.code == "401"
          http.request(req) do |res|
            return false unless res.is_a?(Net::HTTPSuccess)

            opened = true
            res.read_body do |chunk|
              buffer << chunk
              lines, _, buffer = buffer.rpartition("\n")
              events = cfg[:proto].parse(lines)
              next if events.empty?

              changes = events.to_h { |_kind, ch, on| [ ch, on ] }
              with_device(device_id) { |d| DvrEvents.report(d, changes) }
              seen += events.size
              raise StopIteration if limit && seen >= limit
            end
          end
        end
        opened
      rescue StopIteration
        true
      rescue SystemCallError, SocketError, Timeout::Error, IOError, Net::HTTPBadResponse => e
        Rails.logger.warn("[dvr] #{device_id}: #{e.class.name.demodulize}")
        with_device(device_id) { |d| DvrEvents.report(d, {}, quality: "unavailable") }
        opened
      end

      def running = @threads.keys

      private

      def with_device(device_id)
        Rails.application.executor.wrap do
          device = ActsAsTenant.without_tenant { Device.find_by(id: device_id) }
          device && ActsAsTenant.with_tenant(device.tenant) { yield device }
        end
      end
    end
  end
end
