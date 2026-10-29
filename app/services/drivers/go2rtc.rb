require "net/http"

module Drivers
  # Câmeras pelo go2rtc do servidor local (GO2RTC_URL, só na rede interna do
  # compose; quem vê passa pelo Rails, com o papel no local). Só visualização:
  # não há comando. Dispositivo `go2rtc`: `address` {host, port, username},
  # `credential` = senha (cifrada); cada ponto `stream` é um canal, com
  # `address` {"path" => "/Streaming/Channels/102"}. Vale o aprendido no DVR:
  # substream (x02) e RTSP sobre TCP (o padrão do go2rtc).
  #
  # O go2rtc não guarda configuração: `sync!` (a cada minuto, no worker) põe
  # nele, pela API, um stream por ponto (nome = id do ponto) e tira os que
  # sobraram. Aparelho com usuário e sem senha fica de fora (não insiste com
  # senha errada: o DVR bloqueia o usuário).
  module Go2rtc
    class Error < StandardError; end

    SNAPSHOT_TTL = 3 # s: vários olhando a mesma câmera usam o mesmo quadro
    SNAPSHOT_DIR = Rails.root.join("tmp/snapshots")
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def url = ENV["GO2RTC_URL"].presence

    def source(point)
      d = point.device
      a = d.address
      return if a["host"].blank? || point.address["path"].blank?
      return if a["username"].present? && d.credential.blank?

      auth = a["username"].present? ? "#{ERB::Util.url_encode(a['username'])}:#{ERB::Util.url_encode(d.credential)}@" : ""
      "rtsp://#{auth}#{a['host']}:#{a['port'].presence || 554}#{point.address['path']}"
    end

    def points = Point.joins(:device).includes(:device).where(capability: "stream", disabled: false, devices: { driver: "go2rtc", disabled: false })

    # Streams desejados (id do ponto → fonte), de todas as empresas do servidor.
    def wanted = ActsAsTenant.without_tenant { points.to_a }.filter_map { |p| (s = source(p)) && [ p.id, s ] }.to_h

    def sync!
      return unless url

      current = JSON.parse(request(Net::HTTP::Get, "/api/streams").body.presence || "{}")
      want = wanted
      want.each do |name, src|
        next if Array(current.dig(name, "producers")).any? { |pr| pr["url"] == src }

        # Sem arquivo de config o go2rtc cria o stream e responde 400 ("Config file disabled").
        request(Net::HTTP::Put, "/api/streams", { name: name, src: src }, ok: [ 400 ])
      end
      (current.keys.grep(UUID) - want.keys).each { |name| request(Net::HTTP::Delete, "/api/streams", { src: name }) }
      want.size
    end

    # JPEG do último quadro; guarda só o último no disco (não vai para o histórico).
    def snapshot(point)
      file = SNAPSHOT_DIR.join("#{point.id}.jpg")
      return file.binread if file.exist? && file.mtime > SNAPSHOT_TTL.seconds.ago

      raise Error, "Câmera sem conexão." unless url && source(point)

      jpeg = request(Net::HTTP::Get, "/api/frame.jpeg", { src: point.id }).body
      FileUtils.mkdir_p(SNAPSHOT_DIR)
      file.binwrite(jpeg)
      quality!(point, "good")
      jpeg
    rescue Error
      quality!(point, "unavailable")
      raise
    end

    # WebRTC: a oferta SDP do navegador vai ao go2rtc e a resposta volta.
    def webrtc(point, offer)
      raise Error, "Câmera sem conexão." unless url && source(point)

      request(Net::HTTP::Post, "/api/webrtc", { src: point.id }, body: offer).body
    end

    def request(klass, path, params = {}, body: nil, ok: [])
      uri = URI.join(url, path)
      uri.query = URI.encode_www_form(params) if params.any?
      req = klass.new(uri)
      req.body = body if body
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 12) { |h| h.request(req) }
      raise Error, "go2rtc respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess) || ok.include?(res.code.to_i)

      res
    rescue SystemCallError, SocketError, Timeout::Error, IOError => e
      raise Error, "go2rtc fora do ar (#{e.class.name.demodulize})."
    end

    # [{name, host, port, username, password, area, streams: [{name, path}]}] →
    # dispositivos e pontos `stream` (idempotente por host e caminho). Senha
    # vazia mantém a que já está gravada.
    def import!(site, list)
      count = { devices: 0, points: 0 }
      list.each do |cam|
        device = site.devices.where(driver: "go2rtc").find_by("address->>'host' = ?", cam["host"]) || site.devices.new(driver: "go2rtc")
        count[:devices] += 1 if device.new_record?
        area = site.areas.find_by(name: cam["area"]) if cam["area"].present?
        device.assign_attributes(name: cam["name"], area: area || device.area,
                                 address: { "host" => cam["host"], "port" => cam["port"], "username" => cam["username"] }.compact_blank)
        device.credential = cam["password"] if cam["password"].present?
        device.save!
        Array(cam["streams"]).each do |s|
          next if device.points.any? { |p| p.address["path"] == s["path"] }

          device.points.create!(site: site, name: s["name"], capability: "stream", history: "none", address: { "path" => s["path"] })
          count[:points] += 1
        end
      end
      count
    end

    def quality!(point, quality)
      point.report!(point.value, quality: quality) unless point.quality == quality
    end
  end
end
