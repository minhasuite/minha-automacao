module Integrations
  # Speedtest Tracker (app do catálogo): lê o último teste pela API do
  # próprio Speedtest Tracker (`/api/v1/results/latest`, token criado em
  # Configurações → API Tokens dele, com "results:read"). Download, upload,
  # latência e a hora do último teste viram pontos de medição, para alertas
  # de "internet ruim". Quem mede é o app; aqui só se lê (nada de teste extra).
  class SpeedtestTrackerPlugin < SchemaPlugin
    describe key: "speedtest_tracker", title: "Speedtest Tracker", icon: "trending-up",
             description: "Velocidade da internet medida pelo Speedtest Tracker da casa: download, upload, latência e a hora do último teste como pontos, para gráficos e alertas."
    texts "pt-BR" => { fields: { token: "Token da API" }, hints: { url: "http://192.168.0.10:8765", token: "Speedtest Tracker → API Tokens (results:read)" },
                       points: { last_test: "Último teste" }, no_result: "O Speedtest Tracker ainda não tem teste." },
          en: { title: "Speedtest Tracker", description: "Internet speed measured by your Speedtest Tracker: download, upload, latency and the last test time as points, for charts and alerts.",
                fields: { token: "API token" }, hints: { url: "http://192.168.0.10:8765", token: "Speedtest Tracker → API Tokens (results:read)" },
                points: { last_test: "Last test" }, no_result: "Speedtest Tracker has no test yet." },
          es: { title: "Speedtest Tracker", description: "Velocidad de internet medida por el Speedtest Tracker de casa: descarga, subida, latencia y la hora de la última prueba como puntos, para gráficos y alertas.",
                fields: { token: "Token de la API" }, hints: { url: "http://192.168.0.10:8765", token: "Speedtest Tracker → API Tokens (results:read)" },
                points: { last_test: "Última prueba" }, no_result: "Speedtest Tracker aún no tiene pruebas." }
    field :url, :url, required: true
    field :token, secret: true, required: true

    class << self
      def latest(integration)
        base = LanHttp.base(conf(integration, :url)) or raise(Integrations::Error, field_label(:url))
        data = LanHttp.get("#{base}/api/v1/results/latest", headers: { "Authorization" => "Bearer #{conf(integration, :token)}", "Accept" => "application/json" })["data"]
        data.is_a?(Hash) ? data : raise(Integrations::Error, text(:no_result))
      end

      def entries(integration)
        latest(integration)
        host = URI(LanHttp.base(conf(integration, :url))).host
        [ entry(id: "speedtest_tracker:#{host}", name: integration.name, manufacturer: "Speedtest Tracker", poll_s: 600,
                points: [ point("download", unit: "Mbit/s", state_class: "measurement", icon: "download"),
                          point("upload", unit: "Mbit/s", state_class: "measurement", icon: "upload"),
                          point("ping", unit: "ms", state_class: "measurement"), point("last_test", "datetime") ]) ]
      end

      # bits/s (`download_bits`) ou bytes/s (`download`) → Mbit/s.
      def mbits(data, kind)
        bits = data["#{kind}_bits"] || (data[kind] && data[kind].to_f * 8)
        bits && (bits.to_f / 1_000_000).round(1)
      end

      def time(text)
        Time.zone.parse(text.to_s)
      rescue ArgumentError
        nil
      end

      def read(device)
        d = latest(device.integration)
        at = time(d["updated_at"].presence || d["created_at"])
        { "download" => mbits(d, "download"), "upload" => mbits(d, "upload"), "ping" => d["ping"]&.to_f&.round(1), "last_test" => at&.iso8601 }
      end
    end
  end
end
