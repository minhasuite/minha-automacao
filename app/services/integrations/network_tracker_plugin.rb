require "open3"
require "socket"

module Integrations
  # Rastreador de rede (Pacote 3; o `ping`/`device_tracker` de roteador do
  # HA): cada endereço da lista (celular, notebook) vira um aparelho com o
  # ponto "Conectado" (presença), que serve de fonte para a Pessoa. Só lê:
  # um ping ou uma tentativa de conexão TCP por endereço a cada leitura.
  # Como o celular dorme e some da rede por minutos, "desconectado" só vale
  # depois do `consider_home_s` sem resposta.
  #
  # Jeito de testar = módulo em `PROBES` (`label`, `up?(host, settings)`).
  class NetworkTrackerPlugin < Plugin
    describe key: "network_tracker", title: "Rastreador de rede", icon: "status-online",
             description: "Celulares e outros aparelhos na rede de casa (ping ou conexão), como presença das pessoas."
    texts "pt-BR" => { probe_ping: "Ping (ICMP)", probe_tcp: "Conexão TCP (porta)", no_ping: "Este servidor não tem o comando ping; use \"Conexão TCP\".", ready: "Rastreador de rede pronto", updated: "Rastreador de rede atualizado", hosts_alert: "Informe ao menos um endereço válido, um por linha (Nome = 192.168.0.10).", read_ok: "%{notice}: %{online} de %{found} na rede agora.", read_failed: "Salvo, mas a leitura falhou: %{error}" },
          en: { title: "Network tracker", description: "Phones and other devices on your home network (ping or connection), as people's presence.", probe_ping: "Ping (ICMP)", probe_tcp: "TCP connection (port)", no_ping: "This server doesn't have the ping command; use \"TCP connection\".", ready: "Network tracker ready", updated: "Network tracker updated", hosts_alert: "Enter at least one valid address, one per line (Name = 192.168.0.10).", read_ok: "%{notice}: %{online} of %{found} on the network now.", read_failed: "Saved, but reading failed: %{error}" },
          es: { title: "Rastreador de red", description: "Celulares y otros aparatos en la red de casa (ping o conexión), como presencia de las personas.", probe_ping: "Ping (ICMP)", probe_tcp: "Conexión TCP (puerto)", no_ping: "Este servidor no tiene el comando ping; usa \"Conexión TCP\".", ready: "Rastreador de red listo", updated: "Rastreador de red actualizado", hosts_alert: "Ingresa al menos una dirección válida, una por línea (Nombre = 192.168.0.10).", read_ok: "%{notice}: %{online} de %{found} en la red ahora.", read_failed: "Guardado, pero la lectura falló: %{error}" }

    POLL_S = 60
    CONSIDER_HOME_S = 180
    MAX_HOSTS = 30
    HOST = /\A[a-z0-9]([a-z0-9.:-]{0,251}[a-z0-9])?\z/i

    module Ping
      def self.label = NetworkTrackerPlugin.text(:probe_ping)

      def self.up?(host, _settings)
        _out, status = Open3.capture2e("ping", "-c", "1", "-W", "1", host)
        status.success?
      rescue Errno::ENOENT
        raise Integrations::Error, NetworkTrackerPlugin.text(:no_ping)
      end
    end

    # Recusa (RST) também é sinal de vida: o aparelho respondeu.
    module Tcp
      def self.label = NetworkTrackerPlugin.text(:probe_tcp)

      def self.up?(host, settings)
        Socket.tcp(host, (settings["port"] || 80).to_i, connect_timeout: 1).close
        true
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        true
      rescue SystemCallError, SocketError, IOError
        false
      end
    end

    PROBES = { "ping" => "Ping", "tcp" => "Tcp" }.freeze

    def self.probe(key) = const_get(PROBES.fetch(key.to_s) { PROBES.values.first })
    def self.probes = PROBES.to_h { |k, n| [ k, const_get(n).label ] }

    def self.setup(site, form)
      integration = new_integration(site, name: form[:name].presence || title, poll_s: POLL_S)
      configure(integration, form) or return outcome(:form, alert: hosts_alert)
      integration.save!
      read(integration, text(:ready))
    end

    def self.login(integration, form)
      configure(integration, form) or return outcome(:connect, integration: integration, alert: hosts_alert)
      integration.save!
      read(integration, text(:updated))
    end

    def self.hosts_alert = text(:hosts_alert)

    def self.configure(integration, form)
      hosts = parse_hosts(form[:hosts])
      return false if hosts.empty?

      consider = Automations::Dsl.seconds(form[:consider_home].presence || "#{CONSIDER_HOME_S}s") || CONSIDER_HOME_S
      port = form[:port].to_s.to_i
      integration.settings = integration.settings.merge("account" => "#{hosts.size} endereço(s)", "hosts" => hosts,
                                                        "method" => PROBES.key?(form[:method].to_s) ? form[:method].to_s : PROBES.keys.first,
                                                        "port" => port.between?(1, 65_535) ? port : 80, "consider_home_s" => consider.clamp(0, 3600))
      true
    end

    # "Nome = host" (ou só o host), um por linha.
    def self.parse_hosts(text)
      text.to_s.lines.filter_map do |line|
        name, host = line.include?("=") ? line.split("=", 2).map(&:strip) : [ nil, line.strip ]
        { "name" => (name.presence || host).first(60), "host" => host.downcase } if host.match?(HOST)
      end.uniq { |h| h["host"] }.first(MAX_HOSTS)
    end

    def self.hosts_text(integration) = Array(integration&.settings&.dig("hosts")).map { |h| "#{h['name']} = #{h['host']}" }.join("\n")

    def self.read(integration, notice)
      r = Integrations.sync!(integration)
      outcome(:index, notice: text(:read_ok, notice: notice, online: r[:online], found: r[:found]))
    rescue Integrations::Error => e
      outcome(:index, alert: text(:read_failed, error: e.message))
    end

    def self.custom_sync? = true

    def self.sync!(integration)
      s = integration.settings
      probe = probe(s["method"])
      online = 0
      Array(s["hosts"]).each do |h|
        point = point_for(integration, h)
        up = probe.up?(h["host"], s)
        online += 1 if up
        seen = up ? Time.current : last_seen(point)
        away = !up && (seen.nil? || seen < Time.current - s["consider_home_s"].to_i)
        point.report!(up || !away)
        point.report_attrs!(point.attrs.to_h.merge("host" => h["host"], "last_seen" => seen&.iso8601).compact)
        point.device.update_columns(last_seen_at: seen) if up # rubocop:disable Rails/SkipsModelValidations
      end
      integration.ok!
      { found: Array(s["hosts"]).size, online: online, fresh: 0, removed: 0, keys: 0 }
    rescue Integrations::Error => e
      integration.error!(e.message)
      raise
    end

    def self.last_seen(point)
      raw = point.attrs.to_h["last_seen"]
      raw.present? ? Time.zone.parse(raw.to_s) : nil
    rescue ArgumentError
      nil
    end

    def self.point_for(integration, h)
      site = integration.site
      device = site.devices.find_or_create_by!(driver: "virtual", external_id: "net:#{integration.id}:#{h['host']}") do |d|
        d.name = h["name"]
        d.integration = integration
        d.manufacturer = title
      end
      device.points.find_by(device_class: "presence") ||
        device.points.create!(site: site, name: "Conectado", capability: "onoff", device_class: "presence", history: "on_change",
                              key: Integrations.unique_key(site, device, "Conectado")).tap { |p| p.update!(writable: false) }
    end
  end
end
