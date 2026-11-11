module Integrations
  # InfluxDB (catalogo; app do catálogo): as leituras do histórico (número ou
  # liga/desliga) vão para o InfluxDB do dono, como o `influxdb` do HA:
  # medição = unidade (ou "state"), tags entity_id/domain/area e campo
  # `value`. Em lote, pelo worker: a cada minuto (`tick`, RunSchedulesJob) lê
  # as `readings` novas desde o cursor (`settings.exported_at`) e manda até
  # BATCH linhas num pedido só. Nada no caminho do `Point#report!` (nenhuma
  # tarefa por leitura) e nada gravado no banco além do cursor. Falhou: o
  # cursor fica e tenta no minuto seguinte (atraso máximo de MAX_LAG).
  # InfluxDB 2.x (org, bucket e token) ou 1.x (banco, usuário e senha).
  class InfluxdbPlugin < SchemaPlugin
    describe key: "influxdb", title: "InfluxDB", icon: "chart-bar",
             description: "Manda cada leitura dos aparelhos para o seu InfluxDB (1.x ou 2.x), para gráficos de longo prazo no Grafana e afins."
    texts "pt-BR" => { fields: { version: "Versão", org: "Organização (2.x)", bucket: "Bucket (2.x) ou banco (1.x)" },
                       options: { version: { v2: "InfluxDB 2.x / Cloud", v1: "InfluxDB 1.x" } }, hints: { url: "http://192.168.0.10:8086" },
                       ok: "InfluxDB conectado: as leituras novas já vão para lá." },
          en: { title: "InfluxDB", description: "Sends every device reading to your InfluxDB (1.x or 2.x), for long-term charts in Grafana and the like.",
                fields: { version: "Version", org: "Organization (2.x)", bucket: "Bucket (2.x) or database (1.x)" },
                options: { version: { v2: "InfluxDB 2.x / Cloud", v1: "InfluxDB 1.x" } }, hints: { url: "http://192.168.0.10:8086" },
                ok: "InfluxDB connected: new readings now go there." },
          es: { title: "InfluxDB", description: "Envía cada lectura de los aparatos a tu InfluxDB (1.x o 2.x), para gráficos de largo plazo en Grafana y similares.",
                fields: { version: "Versión", org: "Organización (2.x)", bucket: "Bucket (2.x) o base (1.x)" },
                options: { version: { v2: "InfluxDB 2.x / Cloud", v1: "InfluxDB 1.x" } }, hints: { url: "http://192.168.0.10:8086" },
                ok: "InfluxDB conectado: las lecturas nuevas ya van allí." }
    field :url, :url, required: true
    field :version, :select, options: %w[v2 v1], default: "v2"
    field :org
    field :bucket, required: true
    field :token, secret: true
    field :username
    field :password, secret: true

    BATCH = 5000
    MAX_LAG = 1.day

    class << self
      def entries(_integration) = []
      def custom_sync? = true

      def login(integration, form)
        o = super
        o.alert ? o : outcome(:index, notice: text(:ok))
      end

      # Varredura = escrever um ponto de teste (confere endereço, bucket e token).
      def sync!(integration)
        write!(integration, [ "ma_ping,source=minha_automacao value=1i #{Time.current.to_i}" ])
        integration.update_columns(settings: integration.settings.merge("exported_at" => Time.current.iso8601(6))) if integration.settings["exported_at"].blank? # rubocop:disable Rails/SkipsModelValidations
        integration.ok!
        { found: 0, fresh: 0, removed: 0, keys: 0 }
      rescue Integrations::Error => e
        integration.error!(e.message)
        raise
      end

      def write!(integration, lines)
        base = LanHttp.base(conf(integration, :url)) or raise(Integrations::Error, field_label(:url))
        bucket = conf(integration, :bucket).to_s
        if conf(integration, :version) == "v1"
          q = { db: bucket, precision: "s", u: conf(integration, :username), p: conf(integration, :password) }.compact
          LanHttp.post("#{base}/write?#{q.to_query}", lines.join("\n"), headers: { "Content-Type" => "text/plain" }, raw: true)
        else
          q = { org: conf(integration, :org), bucket: bucket, precision: "s" }.compact
          LanHttp.post("#{base}/api/v2/write?#{q.to_query}", lines.join("\n"), headers: { "Content-Type" => "text/plain", "Authorization" => "Token #{conf(integration, :token)}" }, raw: true)
        end
      end

      def esc(s) = s.to_s.gsub(/([,= ])/, '\\\\\1')

      def line(point, value, at)
        field = point.bool? ? "#{value.to_i}i" : value.to_f.to_s
        tags = { entity_id: point.key, domain: point.capability, area: (point.area || point.device&.area)&.name }.compact_blank
        "#{esc(point.unit.presence || 'state')},#{tags.map { |k, x| "#{k}=#{esc(x)}" }.join(',')} value=#{field} #{at.to_i}"
      end

      # --- exportação em lote (Integrations.tick, a cada minuto) ---
      def tick(now)
        ActsAsTenant.without_tenant do
          Integration.where(driver: driver).includes(:tenant).find_each do |i|
            ActsAsTenant.with_tenant(i.tenant) { export!(i, now) }
          end
        end
      end

      def cursor(integration)
        Time.zone.parse(integration.settings["exported_at"].to_s)
      rescue ArgumentError
        nil
      end

      # → quantas leituras foram. Lê só o que o histórico já gravou (números e liga/desliga).
      def export!(integration, now = Time.current)
        from = [ cursor(integration) || now, now - MAX_LAG ].max
        to = now - 2.seconds
        rows = Reading.joins(:point).where(points: { site_id: integration.site_id }).where(at: from...to).where.not(value: nil)
                      .order(:at).limit(BATCH).pluck(:point_id, :at, :value)
        if rows.any?
          points = Point.where(id: rows.map(&:first).uniq).includes(:area, device: :area).index_by(&:id)
          write!(integration, rows.filter_map { |pid, at, v| (p = points[pid]) && line(p, v, at) })
          to = rows.last[1] + 0.000001 if rows.size == BATCH
        end
        integration.update_columns(settings: integration.settings.merge("exported_at" => to.iso8601(6))) # rubocop:disable Rails/SkipsModelValidations
        integration.ok! if integration.status != "ok"
        rows.size
      rescue Integrations::Error => e
        integration.error!(e.message)
        0
      end
    end
  end
end
