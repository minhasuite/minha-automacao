module Integrations
  # Roteador por UPnP/IGD (catalogo, o "upnp" do HA): estatísticas do roteador
  # de casa pelo InternetGatewayDevice (SOAP via `Upnp`): IP externo, se a
  # internet está conectada, há quanto tempo, bytes recebidos e enviados e a
  # taxa de agora (calculada entre duas leituras). Só leitura.
  class UpnpPlugin < SchemaPlugin
    describe key: "upnp", title: "Roteador (UPnP/IGD)", icon: "globe-alt",
             description: "Estatísticas do roteador de casa pelo UPnP: internet conectada, IP externo, tempo conectado, dados recebidos e enviados e a velocidade de agora."
    texts "pt-BR" => { points: { connected: "Internet conectada", external_ip: "IP externo", received: "Recebido", sent: "Enviado", rate_down: "Baixando agora", rate_up: "Enviando agora" },
                       no_igd: "O roteador não respondeu como InternetGatewayDevice (ligue o UPnP nele)." },
          en: { title: "Router (UPnP/IGD)", description: "Your home router's statistics over UPnP: internet connected, external IP, connected time, data received and sent and the current speed.",
                points: { connected: "Internet connected", external_ip: "External IP", received: "Received", sent: "Sent", rate_down: "Downloading now", rate_up: "Uploading now" },
                no_igd: "The router didn't answer as an InternetGatewayDevice (turn UPnP on in it)." },
          es: { title: "Router (UPnP/IGD)", description: "Estadísticas del router de casa por UPnP: internet conectada, IP externa, tiempo conectado, datos recibidos y enviados y la velocidad actual.",
                points: { connected: "Internet conectada", external_ip: "IP externa", received: "Recibido", sent: "Enviado", rate_down: "Descargando ahora", rate_up: "Subiendo ahora" },
                no_igd: "El router no respondió como InternetGatewayDevice (activa UPnP en él)." }
    field :host, required: true
    ST = "urn:schemas-upnp-org:device:InternetGatewayDevice:1".freeze
    ssdp ST
    # Endereços comuns da descrição (miniupnpd, FRITZ!Box, TP-Link…) quando o SSDP não acha.
    PATHS = [ ":49000/igddesc.xml", ":1900/igd.xml", ":5000/rootDesc.xml", ":1780/InternetGatewayDevice.xml", ":80/rootDesc.xml" ].freeze

    class << self
      def location(host)
        found = Ssdp.search(ST).find { |s| s["host"] == host }&.dig("txt", "location")
        return found if found

        PATHS.each do |p|
          url = "http://#{host}#{p}"
          return url if LanHttp.get(url, raw: true).to_s.include?("InternetGatewayDevice")
        rescue Integrations::Error
          next
        end
        raise Integrations::Error, text(:no_igd)
      end

      def services(url)
        s = Upnp.describe(url)["services"]
        wan = s["WANIPConnection"] || s["WANPPPConnection"]
        raise Integrations::Error, text(:no_igd) unless wan && s["WANCommonInterfaceConfig"]

        { "wan" => wan, "wan_service" => s.key?("WANIPConnection") ? "WANIPConnection" : "WANPPPConnection", "common" => s["WANCommonInterfaceConfig"] }
      end

      def entries(integration)
        host = conf(integration, :host)
        url = location(host)
        d = Upnp.describe(url)
        [ entry(id: "upnp:#{d['udn'].presence || host}", name: d["name"].presence || title, manufacturer: d["manufacturer"], model: d["model"], poll_s: 30,
                address: services(url), points: [ point("connected", "onoff", device_class: "connectivity", writable: false), point("external_ip", "text", writable: false),
                                                  point("uptime", unit: "h", state_class: "measurement"), point("received", unit: "GB", state_class: "total_increasing"),
                                                  point("sent", unit: "GB", state_class: "total_increasing"), point("rate_down", unit: "Mbit/s", state_class: "measurement"),
                                                  point("rate_up", unit: "Mbit/s", state_class: "measurement") ]) ]
      end

      def call(a, svc, action) = Upnp.soap(a[svc == "common" ? "common" : "wan"], svc == "common" ? "WANCommonInterfaceConfig" : a["wan_service"], action)

      def read(device, now = Time.current)
        a = device.address
        status = call(a, "wan", "GetStatusInfo")
        rx = Upnp.tag(call(a, "common", "GetTotalBytesReceived"), "NewTotalBytesReceived").to_i
        tx = Upnp.tag(call(a, "common", "GetTotalBytesSent"), "NewTotalBytesSent").to_i
        prev = a["last"].to_h
        dt = now.to_f - prev["at"].to_f
        rate = ->(cur, key) { (cur - prev[key].to_i) * 8 / dt / 1_000_000 if prev["at"] && dt.positive? && cur >= prev[key].to_i }
        out = { "connected" => Upnp.tag(status, "NewConnectionStatus") == "Connected", "uptime" => (Upnp.tag(status, "NewUptime").to_i / 3600.0).round(1),
                "external_ip" => Upnp.tag(call(a, "wan", "GetExternalIPAddress"), "NewExternalIPAddress"),
                "received" => (rx / 1e9).round(3), "sent" => (tx / 1e9).round(3), "rate_down" => rate.(rx, "rx")&.round(2), "rate_up" => rate.(tx, "tx")&.round(2) }
        device.update_columns(address: a.merge("last" => { "at" => now.to_f, "rx" => rx, "tx" => tx }))
        out
      end
    end
  end
end
