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
    # Câmera que falhou fica FAIL_HOLD s sem nova tentativa (quadro e ao vivo):
    # sem isso cada pedido de quadro de cada painel aberto (a cada 3 s) refazia
    # tudo, e três câmeras de nuvem fora do ar abriam centenas de conexões
    # para a Tuya em poucos minutos, enchendo o NAT do roteador (10/11/2026:
    # a internet da casa inteira caía com o servidor ligado).
    FAIL_HOLD = 60
    # Endereço da câmera de nuvem (assinado, muda a cada pedido) reaproveitado:
    # trocar a fonte no go2rtc derruba o vídeo e abre outra conexão.
    ON_DEMAND_TTL = 240
    SNAPSHOT_DIR = Rails.root.join("tmp/snapshots")
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def url = ENV["GO2RTC_URL"].presence

    def source(point)
      return on_demand(point) if point.address["on_demand"]

      d = point.device
      a = d.address
      return if a["host"].blank? || point.address["path"].blank?
      return if a["username"].present? && d.credential.blank?

      auth = a["username"].present? ? "#{ERB::Util.url_encode(a['username'])}:#{ERB::Util.url_encode(d.credential)}@" : ""
      port = point.address["port"].presence || a["port"].presence || 554
      "#{a['scheme'].presence || 'rtsp'}://#{auth}#{a['host']}:#{port}#{point.address['path']}"
    end

    def points = Point.joins(:device).includes(:device).where(capability: "stream", disabled: false, devices: { driver: "go2rtc", disabled: false })

    # tapo: fontes do stream = a principal + as que o plugin da integração junta
    # (ex.: tapo:// para falar na Tapo). Uma só vai como texto (como antes).
    def sources(point)
      main = source(point) or return
      extra = point.device.integration&.plugin&.extra_sources(point).to_a
      extra.empty? ? main : [ main, *extra ]
    end

    # Streams desejados (id do ponto → fonte ou lista de fontes), de todas as empresas do servidor.
    def wanted = ActsAsTenant.without_tenant { points.includes(device: :integration).to_a.filter_map { |p| (s = sources(p)) && [ p.id, s ] }.to_h }

    # Um stream ruim não derruba os outros: fica no log e o ponto "unavailable".
    def sync!
      return unless url

      current = JSON.parse(request(Net::HTTP::Get, "/api/streams").body.presence || "{}")
      want = wanted
      want.each do |name, src|
        have = Array(current.dig(name, "producers")).map { |pr| pr["url"] }
        next if (Array(src) - have).empty?

        # Sem arquivo de config o go2rtc cria/apaga o stream e responde 400
        # ("config file disabled"); o mesmo vale para o DELETE abaixo.
        request(Net::HTTP::Put, "/api/streams", { name: name, src: src }, ok: [ 400 ])
      rescue Error => e
        Rails.logger.warn("[go2rtc] stream #{name}: #{e.message}")
        p = ActsAsTenant.without_tenant { Point.find_by(id: name) }
        ActsAsTenant.with_tenant(p.tenant) { quality!(p, "unavailable") } if p
      end
      (current.keys.grep(UUID) - want.keys).each do |name|
        request(Net::HTTP::Delete, "/api/streams", { src: name }, ok: [ 400 ])
      rescue Error => e
        Rails.logger.warn("[go2rtc] remover stream #{name}: #{e.message}")
      end
      want.size
    end

    # JPEG do último quadro; guarda só o último no disco (não vai para o histórico).
    def snapshot(point)
      file = SNAPSHOT_DIR.join("#{point.id}.jpg")
      return (file.exist? ? file.binread : raise(Error, "Sem quadro da câmera ainda.")) if point.address["image"] == "mqtt" # resto: câmera MQTT
      return file.binread if file.exist? && file.mtime > SNAPSHOT_TTL.seconds.ago

      held!(point)
      prepare(point)
      jpeg = request(Net::HTTP::Get, "/api/frame.jpeg", { src: point.id }).body
      FileUtils.mkdir_p(SNAPSHOT_DIR)
      file.binwrite(jpeg)
      quality!(point, "good")
      jpeg
    rescue Error => e
      hold!(point, e) unless e.is_a?(Held)
      quality!(point, "unavailable")
      raise
    end

    class Held < Error; end

    # Falhou há pouco: responde "sem conexão" sem tocar na rede.
    def held!(point)
      msg = Rails.cache.read("go2rtc:falha:#{point.id}") or return
      raise Held, msg
    end

    def hold!(point, error)
      Rails.cache.write("go2rtc:falha:#{point.id}", error.message.truncate(120), expires_in: FAIL_HOLD)
      Rails.cache.delete("go2rtc:fonte:#{point.id}")
    end

    # WebRTC: a oferta SDP do navegador vai ao go2rtc e a resposta volta.
    def webrtc(point, offer)
      held!(point)
      prepare(point)
      request(Net::HTTP::Post, "/api/webrtc", { src: point.id }, body: offer).body
    rescue Error => e
      hold!(point, e) unless e.is_a?(Held)
      raise
    end

    # ondaC2 (C10): áudio de duas vias. O go2rtc toca o endereço no
    # alto-falante da câmera (backchannel do RTSP/ONVIF, Tapo, ISAPI…); no
    # navegador o ao vivo por WebRTC também manda o microfone.
    def play_audio(point, audio_url)
      prepare(point)
      request(Net::HTTP::Post, "/api/streams", { dst: point.id, src: "ffmpeg:#{audio_url}#audio=pcma#input=file" })
    end

    # Lote 9: câmera de nuvem (`address.on_demand`): o plugin da integração dá o
    # endereço de agora (`stream_url`), posto no go2rtc na hora de ver. Fica
    # fora do `sync!` (o endereço vence); o `sync!` tira o stream depois.
    def on_demand(point)
      point.device.integration&.plugin&.stream_url(point)
    rescue StandardError => e
      raise Error, "Câmera sem conexão (#{e.message.truncate(80)})."
    end

    # Câmera de nuvem: pede o endereço à integração no máximo a cada
    # ON_DEMAND_TTL e só troca a fonte no go2rtc quando ele mudou.
    def prepare(point)
      raise Error, "Câmera sem conexão." unless url
      return source(point) || raise(Error, "Câmera sem conexão.") unless point.address["on_demand"]

      key = "go2rtc:fonte:#{point.id}"
      cached = Rails.cache.read(key)
      src = cached || source(point) or raise Error, "Câmera sem conexão."
      return src if cached

      request(Net::HTTP::Put, "/api/streams", { name: point.id, src: src }, ok: [ 400 ])
      Rails.cache.write(key, src, expires_in: ON_DEMAND_TTL)
      src
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
