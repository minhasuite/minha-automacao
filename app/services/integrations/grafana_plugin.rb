module Integrations
  # Grafana (app do catálogo): conectar cria (ou atualiza) pela API do
  # Grafana a fonte de dados do InfluxDB que recebe as leituras (integração
  # InfluxDB) e um painel inicial "Minha Automação" (temperatura, umidade,
  # potência e internet). Nada é lido de volta; refazer = Reconfigurar.
  class GrafanaPlugin < SchemaPlugin
    describe key: "grafana", title: "Grafana", icon: "chart-square-bar",
             description: "Prepara o Grafana da casa: fonte de dados do InfluxDB com as leituras do Minha Automação e um painel inicial pronto."
    texts "pt-BR" => { fields: { influx_url: "InfluxDB visto pelo Grafana", org: "Organização do InfluxDB", bucket: "Bucket do InfluxDB", token: "Token do InfluxDB" },
                       hints: { url: "http://192.168.0.10:3002", influx_url: "http://ma-app-influxdb:8086" },
                       ok: "Grafana pronto: fonte de dados e o painel \"Minha Automação\" criados.",
                       panels: { temperature: "Temperatura (°C)", humidity: "Umidade (%)", power: "Potência (W)", internet: "Internet (Mbit/s)" } },
          en: { title: "Grafana", description: "Sets up your Grafana: an InfluxDB data source with the Minha Automação readings and a ready starter dashboard.",
                fields: { influx_url: "InfluxDB as seen by Grafana", org: "InfluxDB organization", bucket: "InfluxDB bucket", token: "InfluxDB token" },
                hints: { url: "http://192.168.0.10:3002", influx_url: "http://ma-app-influxdb:8086" },
                ok: "Grafana ready: data source and the \"Minha Automação\" dashboard created.",
                panels: { temperature: "Temperature (°C)", humidity: "Humidity (%)", power: "Power (W)", internet: "Internet (Mbit/s)" } },
          es: { title: "Grafana", description: "Prepara el Grafana de casa: fuente de datos de InfluxDB con las lecturas de Minha Automação y un panel inicial listo.",
                fields: { influx_url: "InfluxDB visto por Grafana", org: "Organización de InfluxDB", bucket: "Bucket de InfluxDB", token: "Token de InfluxDB" },
                hints: { url: "http://192.168.0.10:3002", influx_url: "http://ma-app-influxdb:8086" },
                ok: "Grafana listo: fuente de datos y el panel \"Minha Automação\" creados.",
                panels: { temperature: "Temperatura (°C)", humidity: "Humedad (%)", power: "Potencia (W)", internet: "Internet (Mbit/s)" } }
    field :url, :url, required: true
    field :username, default: "admin"
    field :password, secret: true, required: true
    field :influx_url, :url, default: "http://ma-app-influxdb:8086"
    field :org, default: "casa"
    field :bucket, default: "minha_automacao"
    field :token, secret: true, required: true

    UID = "minha-automacao".freeze
    # Painel → unidade (= medição no InfluxDB, ver InfluxdbPlugin#line).
    PANELS = { temperature: "°C", humidity: "%", power: "W", internet: "Mbit/s" }.freeze

    class << self
      def entries(_integration) = []
      def custom_sync? = true

      def login(integration, form)
        o = super
        o.alert ? o : outcome(:index, notice: text(:ok))
      end

      def sync!(integration)
        provision!(integration)
        integration.ok!
        { found: 0, fresh: 0, removed: 0, keys: 0 }
      rescue Integrations::Error => e
        integration.error!(e.message)
        raise
      end

      def api(integration, method, path, body)
        base = LanHttp.base(conf(integration, :url)) or raise(Integrations::Error, field_label(:url))
        auth = "Basic #{Base64.strict_encode64("#{conf(integration, :username)}:#{conf(integration, :password)}")}"
        LanHttp.call(method, "#{base}#{path}", body: body, headers: { "Authorization" => auth })
      end

      def provision!(integration)
        ds = datasource(integration)
        begin
          api(integration, :post, "/api/datasources", ds)
        rescue Integrations::Error => e
          raise unless e.message.include?("409")

          api(integration, :put, "/api/datasources/uid/#{UID}", ds)
        end
        api(integration, :post, "/api/dashboards/db", { dashboard: dashboard(integration), overwrite: true })
      end

      def datasource(integration)
        { uid: UID, name: "Minha Automação", type: "influxdb", access: "proxy", isDefault: true, url: conf(integration, :influx_url),
          jsonData: { version: "Flux", organization: conf(integration, :org), defaultBucket: conf(integration, :bucket) },
          secureJsonData: { token: conf(integration, :token) } }
      end

      def flux(bucket, unit)
        "from(bucket: #{bucket.to_json}) |> range(start: v.timeRangeStart, stop: v.timeRangeStop) " \
          "|> filter(fn: (r) => r._measurement == #{unit.to_json} and r._field == \"value\") " \
          "|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)"
      end

      def dashboard(integration)
        bucket = conf(integration, :bucket).to_s
        panels = PANELS.each_with_index.map do |(key, unit), n|
          { id: n + 1, type: "timeseries", title: text("panels.#{key}"), datasource: { type: "influxdb", uid: UID },
            gridPos: { h: 8, w: 12, x: (n % 2) * 12, y: (n / 2) * 8 }, targets: [ { refId: "A", query: flux(bucket, unit) } ] }
        end
        { uid: UID, title: "Minha Automação", tags: %w[minha-automacao], timezone: "browser", schemaVersion: 39,
          time: { from: "now-24h", to: "now" }, panels: panels }
      end
    end
  end
end
