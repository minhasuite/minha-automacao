require "openssl"
require "socket"

module Integrations
  # Lutron Caséta / RA2 Select / RadioRA 3 pela ponte (resto, grupo 9 #100;
  # o `lutron_caseta` do HA): protocolo LEAP (JSON por linha num TLS na
  # porta 8081, com certificado de cliente). O par de certificados sai do
  # pareamento da ponte (botão atrás dela) pelo `lap-pair` do pylutron-caseta
  # (os mesmos arquivos que o HA guarda): caseta.key, caseta.crt e
  # caseta-bridge.crt. Dimmers (nível), interruptores e tomadas (liga/desliga)
  # e cortinas (abertura em %).
  class LutronCasetaPlugin < SchemaPlugin
    describe key: "lutron_caseta", title: "Lutron Caséta", icon: "light-bulb",
             description: "Dimmers, interruptores, tomadas e cortinas Lutron (Caséta, RA2 Select, RadioRA 3) pela ponte, na rede de casa."
    texts "pt-BR" => { fields: { client_key: "Chave do cliente (caseta.key)", client_cert: "Certificado do cliente (caseta.crt)", bridge_cert: "Certificado da ponte (caseta-bridge.crt)" },
                       hints: { client_key: "Do pareamento: aperte o botão atrás da ponte e rode lap-pair <IP> (pylutron-caseta)." },
                       points: { level: "Nível", position: "Abertura" }, note: "Os três arquivos ficam cifrados aqui; a ponte só aceita quem pareou." },
          en: { title: "Lutron Caséta", description: "Lutron dimmers, switches, plugs and shades (Caséta, RA2 Select, RadioRA 3) through the bridge, on your home network.",
                fields: { client_key: "Client key (caseta.key)", client_cert: "Client certificate (caseta.crt)", bridge_cert: "Bridge certificate (caseta-bridge.crt)" },
                hints: { client_key: "From pairing: press the button on the back of the bridge and run lap-pair <IP> (pylutron-caseta)." },
                points: { level: "Level", position: "Opening" }, note: "The three files are stored encrypted here; the bridge only accepts whoever paired." },
          es: { title: "Lutron Caséta", description: "Dimmers, interruptores, enchufes y cortinas Lutron (Caséta, RA2 Select, RadioRA 3) por el puente, en la red de casa.",
                fields: { client_key: "Clave del cliente (caseta.key)", client_cert: "Certificado del cliente (caseta.crt)", bridge_cert: "Certificado del puente (caseta-bridge.crt)" },
                hints: { client_key: "Del emparejamiento: presiona el botón detrás del puente y ejecuta lap-pair <IP> (pylutron-caseta)." },
                points: { level: "Nivel", position: "Apertura" }, note: "Los tres archivos se guardan cifrados aquí; el puente solo acepta a quien emparejó." }
    field :host, required: true
    field :port, :number, default: 8081
    field :client_key, :textarea, secret: true, required: true
    field :client_cert, :textarea, secret: true, required: true
    field :bridge_cert, :textarea, secret: true, required: true
    mdns "_lutron._tcp"

    class << self
      # Sessão LEAP: bloco recebe `ask.(verbo, url, corpo)` → Body da resposta.
      def leap(integration)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.key = OpenSSL::PKey.read(conf(integration, :client_key).to_s)
        ctx.cert = OpenSSL::X509::Certificate.new(conf(integration, :client_cert).to_s)
        store = OpenSSL::X509::Store.new
        store.add_cert(OpenSSL::X509::Certificate.new(conf(integration, :bridge_cert).to_s))
        ctx.cert_store = store
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.verify_hostname = false # o certificado da ponte é pelo número de série, não pelo IP
        tcp = Socket.tcp(conf(integration, :host), conf(integration, :port).to_i, connect_timeout: 5)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx).tap { |s| s.sync_close = true }
        ssl.connect
        ask = lambda do |type, url, body = nil|
          ssl.write("#{{ CommuniqueType: type, Header: { Url: url }, Body: body }.compact.to_json}\r\n")
          loop do
            raise Integrations::Error, "Lutron: sem resposta" unless ssl.wait_readable(5)

            msg = JSON.parse(ssl.gets.to_s)
            next unless msg.dig("Header", "Url") == url # eventos de outros não interessam aqui

            status = msg.dig("Header", "StatusCode").to_s
            raise Integrations::Error, "Lutron: #{status}" unless status.start_with?("2")

            break msg["Body"].to_h
          end
        end
        yield ask
      rescue OpenSSL::SSL::SSLError => e
        raise Integrations.auth(Integrations::Error.new("Lutron: a ponte recusou o certificado (#{e.message.truncate(60)})"))
      rescue OpenSSL::PKey::PKeyError, OpenSSL::X509::CertificateError => e
        raise Integrations::Error, "Lutron: certificado ou chave inválidos (#{e.class.name.demodulize})"
      rescue *LanPlugin::NET_ERRORS, JSON::ParserError => e
        raise Integrations::Error, "Lutron: #{e.class.name.demodulize}"
      ensure
        ssl&.close
      end

      def kind(type)
        t = type.to_s
        return "shade" if t.match?(/Shade|Blind|Drape/i)
        return "switch" if t.match?(/Switch|Plug(?!.*Dimmer)|Fan/i) && !t.match?(/Dimmer/i)

        "dimmer" if t.match?(/Dimmer|Lamp|Light/i)
      end

      def entries(integration)
        leap(integration) do |ask|
          Array(ask.("ReadRequest", "/device")["Devices"]).filter_map do |d|
            zone = Array(d["LocalZones"]).first&.dig("href") or next
            k = kind(d["DeviceType"]) or next
            pt = case k
            when "dimmer" then point("level", "dimmer", min: 0, max: 100)
            when "switch" then point("switch", "onoff")
            else point("position", "setpoint", unit: "%", min: 0, max: 100, step: 1)
            end
            entry(id: "lutron:#{d['SerialNumber'].presence || d['href']}", name: Array(d["FullyQualifiedName"]).join(" ").presence || d["Name"], model: d["ModelNumber"].presence || d["DeviceType"],
                  address: { "zone" => zone }, poll_s: 60, points: [ pt ])
          end
        end
      end

      def read(device)
        s = leap(device.integration) { |ask| ask.("ReadRequest", "#{device.address['zone']}/status")["ZoneStatus"].to_h }
        level = s["Level"]
        { "level" => level, "position" => level, "switch" => (level.to_i.positive? if level) }
      end

      def write(point, value)
        level = point.capability == "onoff" ? (value ? 100 : 0) : value.to_i.clamp(0, 100)
        body = { Command: { CommandType: "GoToLevel", Parameter: [ { Type: "Level", Value: level } ] } }
        leap(point.device.integration) { |ask| ask.("CreateRequest", "#{point.device.address['zone']}/commandprocessor", body) }
      end
    end
  end
end
