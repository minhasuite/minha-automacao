module Integrations
  # AdGuard Home (catalogo): bloqueador de anúncios e rastreadores da rede pela
  # API de controle (`/control/*`, usuário e senha do painel). Liga/desliga a
  # proteção e os filtros, e mostra consultas, bloqueios e tempo de resposta.
  class AdguardPlugin < SchemaPlugin
    describe key: "adguard", title: "AdGuard Home", icon: "shield-check",
             description: "Bloqueio de anúncios e rastreadores da rede: liga e desliga a proteção, a navegação segura e o controle parental, com as consultas e os bloqueios do dia."
    texts "pt-BR" => { points: { protection: "Proteção", filtering: "Filtros", safebrowsing: "Navegação segura", parental: "Controle parental", safesearch: "Busca segura",
                                 queries: "Consultas DNS", blocked: "Bloqueadas", blocked_ratio: "Bloqueadas (%)", avg_ms: "Tempo de resposta" } },
          en: { title: "AdGuard Home", description: "Network-wide ad and tracker blocking: turn protection, safe browsing and parental control on and off, with today's queries and blocks.",
                points: { protection: "Protection", filtering: "Filters", safebrowsing: "Safe browsing", parental: "Parental control", safesearch: "Safe search",
                          queries: "DNS queries", blocked: "Blocked", blocked_ratio: "Blocked (%)", avg_ms: "Response time" } },
          es: { title: "AdGuard Home", description: "Bloqueo de anuncios y rastreadores en toda la red: activa y desactiva la protección, la navegación segura y el control parental, con las consultas y los bloqueos del día.",
                points: { protection: "Protección", filtering: "Filtros", safebrowsing: "Navegación segura", parental: "Control parental", safesearch: "Búsqueda segura",
                          queries: "Consultas DNS", blocked: "Bloqueadas", blocked_ratio: "Bloqueadas (%)", avg_ms: "Tiempo de respuesta" } }
    field :host, required: true
    field :port, :number, default: 3000
    field :username
    field :password, secret: true

    SWITCHES = %w[protection filtering safebrowsing parental safesearch].freeze

    class << self
      def api(integration, path, body = nil)
        base = LanHttp.base("#{conf(integration, :host)}:#{conf(integration, :port)}")
        auth = "Basic #{Base64.strict_encode64("#{conf(integration, :username)}:#{conf(integration, :password)}")}"
        LanHttp.call(body.nil? ? :get : :post, "#{base}/control/#{path}", body: body, headers: { "Authorization" => auth })
      end

      def entries(integration)
        status = api(integration, "status")
        [ entry(id: "adguard:#{conf(integration, :host)}", name: title, model: status["version"], address: {}, poll_s: 60,
                points: SWITCHES.map { |s| point(s, "onoff", icon: "shield-check") } +
                        [ point("queries", state_class: "measurement"), point("blocked", state_class: "measurement"),
                          point("blocked_ratio", unit: "%", state_class: "measurement"), point("avg_ms", unit: "ms", state_class: "measurement") ]) ]
      end

      def read(device)
        i = device.integration
        status = api(i, "status")
        stats = api(i, "stats")
        queries = stats["num_dns_queries"].to_i
        blocked = stats["num_blocked_filtering"].to_i
        { "protection" => status["protection_enabled"], "filtering" => api(i, "filtering/status")["enabled"],
          "safebrowsing" => api(i, "safebrowsing/status")["enabled"], "parental" => api(i, "parental/status")["enabled"],
          "safesearch" => api(i, "safesearch/status")["enabled"], "queries" => queries, "blocked" => blocked,
          "blocked_ratio" => queries.positive? ? (blocked * 100.0 / queries).round(1) : 0.0, "avg_ms" => (stats["avg_processing_time"].to_f * 1000).round(1) }
      end

      def write(point, value)
        i = point.device.integration
        case (f = point.address["field"])
        when "protection" then api(i, "protection", { enabled: value })
        when "filtering" then api(i, "filtering/config", { enabled: value, interval: api(i, "filtering/status")["interval"] || 24 })
        when "safesearch" then api(i, "safesearch/settings", api(i, "safesearch/status").merge("enabled" => value))
        else api(i, "#{f}/#{value ? 'enable' : 'disable'}", {})
        end
      end
    end
  end
end
