module Integrations
  # Impressora pela IPP (catalogo, o "ipp" do HA; serve também para Brother,
  # Epson, HP e Canon com IPP/AirPrint): pede os atributos da impressora
  # (Get-Printer-Attributes, protocolo binário sobre HTTP) e mostra o estado
  # e o nível de cada tinta/toner. Só leitura.
  class IppPlugin < SchemaPlugin
    describe key: "ipp", title: "Impressora (IPP)", icon: "printer",
             description: "Impressoras da rede com IPP/AirPrint (HP, Epson, Brother, Canon…): estado (pronta, imprimindo, parada) e o nível de cada tinta ou toner."
    texts "pt-BR" => { fields: { path: "Caminho IPP" }, points: { state: "Estado", marker: "%{name}" },
                       states: { idle: "Pronta", processing: "Imprimindo", stopped: "Parada" } },
          en: { title: "Printer (IPP)", description: "Network printers with IPP/AirPrint (HP, Epson, Brother, Canon…): status (idle, printing, stopped) and each ink or toner level.",
                fields: { path: "IPP path" }, points: { state: "Status", marker: "%{name}" }, states: { idle: "Idle", processing: "Printing", stopped: "Stopped" } },
          es: { title: "Impresora (IPP)", description: "Impresoras de la red con IPP/AirPrint (HP, Epson, Brother, Canon…): estado (lista, imprimiendo, detenida) y el nivel de cada tinta o tóner.",
                fields: { path: "Ruta IPP" }, points: { state: "Estado", marker: "%{name}" }, states: { idle: "Lista", processing: "Imprimiendo", stopped: "Detenida" } }
    field :host, required: true
    field :port, :number, default: 631
    field :path, default: "/ipp/print"
    mdns "_ipp._tcp"
    STATES = { 3 => "idle", 4 => "processing", 5 => "stopped" }.freeze
    ASKED = %w[printer-make-and-model printer-state printer-uuid printer-info marker-names marker-levels marker-colors printer-device-id].freeze

    class << self
      def attr(tag, name, value) = [ tag, name.bytesize ].pack("Cn") + name + [ value.bytesize ].pack("n") + value

      # Get-Printer-Attributes (versão 2.0, operação 0x000B).
      def request(uri)
        body = [ 2, 0, 0x000B, 1 ].pack("CCnN") + [ 0x01 ].pack("C") +
               attr(0x47, "attributes-charset", "utf-8") + attr(0x48, "attributes-natural-language", "en") + attr(0x45, "printer-uri", uri) +
               ASKED.each_with_index.map { |a, i| attr(0x44, i.zero? ? "requested-attributes" : "", a) }.join + [ 0x03 ].pack("C")
        body.b
      end

      # Resposta → {"nome" => [valores]} (inteiro, enum e booleano já convertidos).
      def parse(data)
        data = data.b
        pos = 8
        out = {}
        last = nil
        while pos < data.bytesize
          tag = data.getbyte(pos)
          pos += 1
          break if tag == 0x03
          next if tag < 0x10

          nlen = data.byteslice(pos, 2).unpack1("n")
          name = data.byteslice(pos + 2, nlen)
          vlen = data.byteslice(pos + 2 + nlen, 2).unpack1("n")
          raw = data.byteslice(pos + 4 + nlen, vlen)
          pos += 4 + nlen + vlen
          value = case tag
          when 0x21, 0x23 then raw.unpack1("l>")
          when 0x22 then raw.getbyte(0) == 1
          else raw.dup.force_encoding("UTF-8")
          end
          last = name unless nlen.zero?
          (out[last] ||= []) << value if last
        end
        out
      end

      def attributes(integration_or_device)
        a = integration_or_device.is_a?(Device) ? integration_or_device.address : { "host" => conf(integration_or_device, :host), "port" => conf(integration_or_device, :port), "path" => conf(integration_or_device, :path) }
        uri = "ipp://#{a['host']}:#{a['port']}#{a['path']}"
        res = LanHttp.post("http://#{a['host']}:#{a['port']}#{a['path']}", request(uri), headers: { "Content-Type" => "application/ipp" }, raw: true).to_s
        status = res.b.byteslice(2, 2)&.unpack1("n").to_i
        raise Integrations::Error, "IPP: 0x#{status.to_s(16)}" if status >= 0x0400

        parse(res)
      end

      def entries(integration)
        at = attributes(integration)
        names = Array(at["marker-names"])
        [ entry(id: "ipp:#{Array(at['printer-uuid']).first || conf(integration, :host)}", name: Array(at["printer-info"]).first.presence || Array(at["printer-make-and-model"]).first.to_s,
                model: Array(at["printer-make-and-model"]).first, category: "Impressora", poll_s: 300,
                address: { "host" => conf(integration, :host), "port" => conf(integration, :port).to_i, "path" => conf(integration, :path) },
                points: [ point("state", "enum", options: STATES.values.map { |s| text("states.#{s}") }, writable: false, icon: "printer") ] +
                        names.each_index.map { |i| point("marker:#{i}", name: text("points.marker", name: names[i]), unit: "%", state_class: "measurement", icon: "printer") }) ]
      end

      def read(device)
        at = attributes(device)
        state = STATES[Array(at["printer-state"]).first]
        opts = Array(device.points.find { |p| p.address["field"] == "state" }&.options)
        out = { "state" => state && (opts[STATES.values.index(state)] || text("states.#{state}")) }
        Array(at["marker-levels"]).each_with_index { |lvl, i| out["marker:#{i}"] = lvl if lvl.is_a?(Integer) && lvl >= 0 }
        out
      end
    end
  end
end
