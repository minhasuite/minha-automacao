require "net/http"

module Integrations
  # Speedtest (catalogo, o speedtestdotnet do HA): velocidade da internet pelos
  # servidores do Speedtest.net (lista pública do site): latência, download e
  # upload. Mede a cada `poll_s` (padrão 1 h; o teste gasta ~30 MB) ou pelo
  # "Atualizar agora".
  class SpeedtestPlugin < SchemaPlugin
    describe key: "speedtest", title: "Speedtest", icon: "trending-up",
             description: "Velocidade da internet de casa (download, upload e latência) pelos servidores do Speedtest.net, de hora em hora, para gráficos e automações."
    texts "pt-BR" => { fields: { server_id: "Servidor (id, opcional)" }, hints: { server_id: "vazio = o mais perto" }, no_server: "Nenhum servidor do Speedtest respondeu." },
          en: { title: "Speedtest", description: "Your home internet speed (download, upload and latency) through Speedtest.net servers, every hour, for charts and automations.",
                fields: { server_id: "Server (id, optional)" }, hints: { server_id: "empty = the nearest" }, no_server: "No Speedtest server answered." },
          es: { title: "Speedtest", description: "Velocidad de internet de casa (descarga, subida y latencia) mediante los servidores de Speedtest.net, cada hora, para gráficos y automatizaciones.",
                fields: { server_id: "Servidor (id, opcional)" }, hints: { server_id: "vacío = el más cercano" }, no_server: "Ningún servidor de Speedtest respondió." }
    field :server_id

    SERVERS = "https://www.speedtest.net/api/js/servers?engine=js&https_functional=true&limit=5".freeze
    DOWN_BYTES = 25_000_000
    UP_BYTES = 5_000_000

    class << self
      def servers(integration)
        id = integration.settings["server_id"].presence
        res = SafeHttp.get(id ? "#{SERVERS}&search=#{CGI.escape(id)}" : SERVERS, timeout: 15)
        list = JSON.parse(res.body)
        list = list.select { |s| s["id"].to_s == id } if id
        list.presence || raise(Integrations::Error, text(:no_server))
      rescue SafeHttp::Error, JSON::ParserError
        raise Integrations::Error, text(:no_server)
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def http(uri, &)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 60, write_timeout: 60, &)
      end

      # → {ping (ms), download e upload (Mbit/s)} contra o primeiro servidor que responder.
      def measure(server)
        base = "https://#{server['host']}"
        ping = 3.times.map do
          t = clock
          http(URI("#{base}/speedtest/latency.txt")) { |h| h.get("/speedtest/latency.txt?x=#{SecureRandom.hex(4)}") }
          (clock - t) * 1000
        end.min
        got = 0
        t = clock
        uri = URI("#{base}/download?nocache=#{SecureRandom.hex(4)}&size=#{DOWN_BYTES}")
        http(uri) { |h| h.request(Net::HTTP::Get.new(uri)) { |res| res.read_body { |c| got += c.bytesize } } }
        down = got * 8 / [ clock - t, 0.001 ].max / 1_000_000
        up_uri = URI("#{base}/upload?nocache=#{SecureRandom.hex(4)}")
        t = clock
        http(up_uri) { |h| h.post(up_uri.request_uri, SecureRandom.random_bytes(UP_BYTES), "Content-Type" => "application/octet-stream") }
        up = UP_BYTES * 8 / [ clock - t, 0.001 ].max / 1_000_000
        { "ping" => ping.round(1), "download" => down.round(1), "upload" => up.round(1) }
      end

      def entries(integration)
        s = servers(integration).first
        [ entry(id: "speedtest:#{integration.id}", name: integration.name, manufacturer: "Ookla", model: [ s["sponsor"], s["name"] ].compact.join(" · "), poll_s: 3600,
                points: [ point("download", unit: "Mbit/s", state_class: "measurement", icon: "download"), point("upload", unit: "Mbit/s", state_class: "measurement", icon: "upload"),
                          point("ping", unit: "ms", state_class: "measurement") ]) ]
      end

      def read(device)
        servers(device.integration).each do |s|
          return measure(s)
        rescue *LanPlugin::NET_ERRORS, Net::HTTPBadResponse
          next
        end
        raise Integrations::Error, text(:no_server)
      end
    end
  end
end
