require "net/http"

module Integrations
  # FRITZ!Box Tools (catalogo, o "fritz" do HA): o roteador FRITZ!Box pelo
  # TR-064 (SOAP com autenticação digest na porta 49000): tempo ligado, IP
  # externo, Wi-Fi liga/desliga (cada rede) e os aparelhos da rede como
  # presença (escolha quais adicionar).
  class FritzPlugin < SchemaPlugin
    describe key: "fritz", title: "FRITZ!Box (roteador)", icon: "globe-alt",
             description: "Roteador FRITZ!Box: aparelhos conectados como presença, liga e desliga cada Wi-Fi, IP externo e tempo ligado, pelo TR-064."
    texts "pt-BR" => { points: { home: "Conectado", wifi: "Wi-Fi %{n}", external_ip: "IP externo" }, note: "No FRITZ!Box: Rede doméstica → Rede → Configurações de rede → \"Permitir acesso para aplicativos\" (TR-064)." },
          en: { title: "FRITZ!Box (router)", description: "FRITZ!Box router: connected devices as presence, turn each Wi-Fi on and off, external IP and uptime, over TR-064.",
                points: { home: "Connected", wifi: "Wi-Fi %{n}", external_ip: "External IP" }, note: "On the FRITZ!Box: Home Network → Network → Network Settings → \"Allow access for applications\" (TR-064)." },
          es: { title: "FRITZ!Box (router)", description: "Router FRITZ!Box: aparatos conectados como presencia, enciende y apaga cada Wi-Fi, IP externa y tiempo encendido, por TR-064.",
                points: { home: "Conectado", wifi: "Wi-Fi %{n}", external_ip: "IP externa" }, note: "En el FRITZ!Box: Red doméstica → Red → Configuración de red → \"Permitir acceso para aplicaciones\" (TR-064)." }
    field :host, required: true, default: "fritz.box"
    field :username
    field :password, secret: true, required: true
    PORT = 49_000
    MAX_HOSTS = 250

    class << self
      # Digest (RFC 2617, qop=auth): o FRITZ!Box responde 401 com o desafio e aceita o segundo pedido.
      def digest(challenge, user, pass, method, uri)
        c = challenge.to_s.scan(/(\w+)="?([^",]+)"?/).to_h
        ha1 = Digest::MD5.hexdigest("#{user}:#{c['realm']}:#{pass}")
        ha2 = Digest::MD5.hexdigest("#{method}:#{uri}")
        cnonce = SecureRandom.hex(8)
        resp = Digest::MD5.hexdigest("#{ha1}:#{c['nonce']}:00000001:#{cnonce}:auth:#{ha2}")
        %(Digest username="#{user}", realm="#{c['realm']}", nonce="#{c['nonce']}", uri="#{uri}", qop=auth, nc=00000001, cnonce="#{cnonce}", response="#{resp}")
      end

      def soap(integration, path, service, action, args = {})
        urn = service.start_with?("urn:") ? service : "urn:dslforum-org:service:#{service}"
        xml = args.map { |k, v| "<#{k}>#{CGI.escapeHTML(v.to_s)}</#{k}>" }.join
        body = %(<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">) +
               %(<s:Body><u:#{action} xmlns:u="#{urn}">#{xml}</u:#{action}></s:Body></s:Envelope>)
        uri = URI("http://#{conf(integration, :host)}:#{PORT}/upnp/control/#{path}")
        Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
          send = lambda do |auth|
            req = Net::HTTP::Post.new(uri, "Content-Type" => 'text/xml; charset="utf-8"', "SOAPACTION" => "#{urn}##{action}")
            req["Authorization"] = auth if auth
            req.body = body
            http.request(req)
          end
          res = send.call(nil)
          res = send.call(digest(res["www-authenticate"], conf(integration, :username).to_s, conf(integration, :password).to_s, "POST", uri.path)) if res.code == "401"
          raise Integrations.auth(Integrations::Error.new("FRITZ!Box: 401")) if res.code == "401"
          raise Integrations::Error, "FRITZ!Box: #{res.code}" unless res.is_a?(Net::HTTPSuccess)

          res.body.to_s
        end
      rescue *LanPlugin::NET_ERRORS => e
        raise Integrations::Error, "FRITZ!Box: #{e.class.name.demodulize}"
      end

      def tag(xml, name) = Upnp.tag(xml, name)

      def hosts(integration)
        n = [ tag(soap(integration, "hosts", "Hosts:1", "GetHostNumberOfEntries"), "NewHostNumberOfEntries").to_i, MAX_HOSTS ].min
        Array.new(n) do |idx|
          x = soap(integration, "hosts", "Hosts:1", "GetGenericHostEntry", NewIndex: idx)
          { "mac" => tag(x, "NewMACAddress"), "name" => tag(x, "NewHostName"), "active" => tag(x, "NewActive") == "1" }
        end.select { |h| h["mac"].present? }
      end

      # Redes Wi-Fi: WLANConfiguration:1, :2, :3 (2,4 GHz, 5 GHz, convidados) até a primeira que falhar.
      def wifis(integration)
        (1..4).each_with_object([]) do |k, list|
          x = soap(integration, "wlanconfig#{k}", "WLANConfiguration:#{k}", "GetInfo")
          list << { "n" => k, "ssid" => tag(x, "NewSSID"), "on" => tag(x, "NewEnable") == "1" }
        rescue Integrations::Error
          break list
        end
      end

      def entries(integration)
        info = soap(integration, "deviceinfo", "DeviceInfo:1", "GetInfo")
        router = entry(id: "fritz:#{tag(info, 'NewSerialNumber').presence || conf(integration, :host)}", name: tag(info, "NewModelName").presence || title, manufacturer: "AVM",
                       model: tag(info, "NewModelName"), category: "FRITZ!OS #{tag(info, 'NewSoftwareVersion')}".strip, poll_s: 60, address: { "router" => true },
                       points: [ point("uptime", unit: "h", state_class: "measurement"), point("external_ip", "text", writable: false) ] +
                               wifis(integration).map { |w| point("wifi:#{w['n']}", "onoff", name: w["ssid"].presence || text("points.wifi", n: w["n"]), icon: "status-online") })
        clients = hosts(integration).map do |h|
          entry(id: "fritz:host:#{h['mac']}", name: h["name"].presence || h["mac"], manufacturer: "", category: "Cliente", address: { "mac" => h["mac"] }, poll_s: 60,
                points: [ point("home", "onoff", device_class: "presence", writable: false, icon: "device-mobile") ])
        end
        [ router ] + clients
      end

      def read(device)
        i = device.integration
        unless device.address["router"]
          x = soap(i, "hosts", "Hosts:1", "GetSpecificHostEntry", NewMACAddress: device.address["mac"])
          return { "home" => tag(x, "NewActive") == "1" }
        end

        out = { "uptime" => (tag(soap(i, "deviceinfo", "DeviceInfo:1", "GetInfo"), "NewUpTime").to_i / 3600.0).round(1),
                "external_ip" => tag(soap(i, "wanipconnection1", "urn:schemas-upnp-org:service:WANIPConnection:1", "GetExternalIPAddress"), "NewExternalIPAddress") }
        wifis(i).each { |w| out["wifi:#{w['n']}"] = w["on"] }
        out
      end

      def write(point, value)
        k = point.address["field"].split(":").last
        soap(point.device.integration, "wlanconfig#{k}", "WLANConfiguration:#{k}", "SetEnable", NewEnable: value ? 1 : 0)
      end
    end
  end
end
