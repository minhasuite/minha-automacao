module Integrations
  # UniFi Network (catalogo): controladora UniFi (UDM/UDR/Cloud Key com UniFi
  # OS ou a controladora antiga) pela API da rede. Os clientes da rede viram
  # presença (escolha quais adicionar, como o rastreador do HA) e os aparelhos
  # UniFi (APs, switches, gateway) mostram se estão no ar, quantos clientes e
  # há quanto tempo estão ligados. Cliente pode ser bloqueado/liberado.
  class UnifiPlugin < SchemaPlugin
    describe key: "unifi", title: "UniFi Network", icon: "status-online",
             description: "Rede UniFi: celulares e aparelhos conectados como presença, APs e switches (no ar, clientes, tempo ligado) e bloquear ou liberar um cliente."
    texts "pt-BR" => { fields: { site: "Site da controladora" }, hints: { port: "443 (UniFi OS) ou 8443 (controladora antiga)" },
                       points: { home: "Conectado", blocked: "Bloqueado", clients: "Clientes", online: "No ar" },
                       note: "Crie um usuário local na controladora (só leitura basta, a não ser para bloquear clientes)." },
          en: { title: "UniFi Network", description: "UniFi network: phones and devices connected as presence, APs and switches (up, clients, uptime) and blocking or unblocking a client.",
                fields: { site: "Controller site" }, hints: { port: "443 (UniFi OS) or 8443 (legacy controller)" },
                points: { home: "Connected", blocked: "Blocked", clients: "Clients", online: "Up" },
                note: "Create a local user on the controller (read-only is enough, unless you want to block clients)." },
          es: { title: "UniFi Network", description: "Red UniFi: teléfonos y aparatos conectados como presencia, APs y switches (en línea, clientes, tiempo encendido) y bloquear o liberar un cliente.",
                fields: { site: "Sitio de la controladora" }, hints: { port: "443 (UniFi OS) u 8443 (controladora antigua)" },
                points: { home: "Conectado", blocked: "Bloqueado", clients: "Clientes", online: "En línea" },
                note: "Crea un usuario local en la controladora (solo lectura basta, salvo para bloquear clientes)." }
    field :host, required: true
    field :port, :number, default: 443
    field :username, required: true
    field :password, secret: true, required: true
    field :site, default: "default"
    CONSIDER_HOME_S = 180

    class << self
      # Login (UniFi OS em /api/auth/login, antiga em /api/login) → bloco recebe chamar(método, caminho, corpo).
      def session(integration)
        root = "https://#{conf(integration, :host)}:#{conf(integration, :port)}"
        creds = { username: conf(integration, :username), password: conf(integration, :password) }
        cookie = csrf = nil
        prefix = "/proxy/network"
        grab = ->(r) { cookie, csrf = r.get_fields("set-cookie").to_a.map { |c| c.split(";").first }.join("; "), r["x-csrf-token"] }
        begin
          LanHttp.call(:post, "#{root}/api/auth/login", body: creds, insecure: true, &grab)
        rescue Integrations::Error => e
          raise if e.is_a?(Integrations::AuthError)

          prefix = ""
          LanHttp.call(:post, "#{root}/api/login", body: creds, insecure: true, &grab)
        end
        site = CGI.escape(conf(integration, :site).to_s)
        yield lambda { |method, path, body = nil|
          h = { "Cookie" => cookie.to_s }
          h["X-CSRF-Token"] = csrf if csrf
          Array(LanHttp.call(method, "#{root}#{prefix}/api/s/#{site}/#{path}", body: body, headers: h, insecure: true)["data"])
        }
      end

      def entries(integration)
        session(integration) do |call|
          clients = call.(:get, "stat/sta").map do |c|
            entry(id: "unifi:client:#{c['mac']}", name: c["name"].presence || c["hostname"].presence || c["mac"], manufacturer: c["oui"].presence || title,
                  model: c["is_wired"] ? "Cabo" : c["essid"], category: "Cliente", address: { "mac" => c["mac"] }, poll_s: 60,
                  points: [ point("home", "onoff", device_class: "presence", writable: false, icon: "device-mobile"), point("blocked", "onoff", icon: "ban") ])
          end
          devices = call.(:get, "stat/device").map do |d|
            entry(id: "unifi:device:#{d['mac']}", name: d["name"].presence || d["model"], manufacturer: "Ubiquiti", model: d["model"], category: d["type"],
                  address: { "mac" => d["mac"], "device" => true }, poll_s: 60,
                  points: [ point("online", "onoff", device_class: "connectivity", writable: false), point("clients", state_class: "measurement"),
                            point("uptime", unit: "h", state_class: "measurement") ])
          end
          devices + clients
        end
      end

      def read(device)
        mac = device.address["mac"]
        session(device.integration) do |call|
          if device.address["device"]
            d = call.(:get, "stat/device/#{mac}").first.to_h
            next { "online" => d["state"] == 1, "clients" => d["num_sta"], "uptime" => d["uptime"] && (d["uptime"].to_i / 3600.0).round(1) }
          end
          c = call.(:get, "stat/sta").find { |x| x["mac"] == mac }
          blocked = call.(:get, "rest/user").find { |x| x["mac"] == mac }.to_h["blocked"] == true
          home = c.present? && Time.current.to_i - c["last_seen"].to_i < CONSIDER_HOME_S
          { "home" => home, "blocked" => blocked }
        end
      end

      def write(point, value)
        session(point.device.integration) { |call| call.(:post, "cmd/stamgr", { cmd: value ? "block-sta" : "unblock-sta", mac: point.device.address["mac"] }) }
      end
    end
  end
end
