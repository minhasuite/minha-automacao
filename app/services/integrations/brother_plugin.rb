module Integrations
  # Impressora Brother (e qualquer uma com a Printer MIB) por SNMP (resto,
  # grupo 9 #38; o `brother` do HA): estado, contador de páginas e o nível de
  # cada suprimento (toner, tinta, cilindro, correia), com o nome que a própria
  # impressora dá. Só leitura. A IppPlugin continua para estado e toner pelo IPP.
  class BrotherPlugin < SchemaPlugin
    describe key: "brother", title: "Impressora Brother (SNMP)", icon: "printer",
             description: "Impressoras Brother e outras com SNMP: páginas impressas, estado e quanto resta de toner, tinta, cilindro e correia."
    texts "pt-BR" => { fields: { community: "Comunidade SNMP" }, hints: { community: "public (padrão das impressoras)" },
                       points: { pages: "Páginas impressas", status: "Estado", supply: "%{name} restante" },
                       states: { "1" => "outro", "2" => "desconhecido", "3" => "pronta", "4" => "imprimindo", "5" => "aquecendo" }, no_printer: "O aparelho não respondeu como impressora (Printer MIB)." },
          en: { title: "Brother printer (SNMP)", description: "Brother and other SNMP printers: pages printed, status and how much toner, ink, drum and belt is left.",
                fields: { community: "SNMP community" }, hints: { community: "public (printer default)" },
                points: { pages: "Pages printed", status: "Status", supply: "%{name} left" },
                states: { "1" => "other", "2" => "unknown", "3" => "idle", "4" => "printing", "5" => "warming up" }, no_printer: "The device didn't answer as a printer (Printer MIB)." },
          es: { title: "Impresora Brother (SNMP)", description: "Impresoras Brother y otras con SNMP: páginas impresas, estado y cuánto queda de tóner, tinta, tambor y correa.",
                fields: { community: "Comunidad SNMP" }, hints: { community: "public (predeterminado de las impresoras)" },
                points: { pages: "Páginas impresas", status: "Estado", supply: "%{name} restante" },
                states: { "1" => "otro", "2" => "desconocido", "3" => "lista", "4" => "imprimiendo", "5" => "calentando" }, no_printer: "El aparato no respondió como impresora (Printer MIB)." }
    field :host, required: true
    field :community, default: "public"
    dhcp({ hostname: "brn*" }, { hostname: "brw*" }) # nome padrão das Brother na rede

    SYS_DESCR = "1.3.6.1.2.1.1.1.0".freeze
    SERIAL = "1.3.6.1.2.1.43.5.1.1.17.1".freeze
    PAGES = "1.3.6.1.2.1.43.10.2.1.4.1.1".freeze
    STATUS = "1.3.6.1.2.1.25.3.5.1.1.1".freeze
    SUPPLY = "1.3.6.1.2.1.43.11.1.1".freeze # .6 descrição, .8 capacidade, .9 nível
    SLOTS = (1..8).freeze

    class << self
      def snmp(integration, oids) = Snmp.get(conf(integration, :host), oids, community: conf(integration, :community))

      def entries(integration)
        info = snmp(integration, [ SYS_DESCR, SERIAL, PAGES ] + SLOTS.map { |n| "#{SUPPLY}.6.1.#{n}" })
        raise Integrations::Error, text(:no_printer) unless info.key?(PAGES) || info.keys.any? { |k| k.start_with?(SUPPLY) }

        supplies = SLOTS.filter_map { |n| (d = info["#{SUPPLY}.6.1.#{n}"]).present? && point("supply_#{n}", unit: "%", state_class: "measurement", name: text("points.supply", name: d)) }
        [ entry(id: "brother:#{info[SERIAL].presence || conf(integration, :host)}", name: info[SYS_DESCR].to_s.split(/[;,]/).first.presence || title,
                model: info[SYS_DESCR].to_s.truncate(60), serial: info[SERIAL], poll_s: 300,
                points: [ point("status", "text", writable: false), point("pages", state_class: "total_increasing", icon: "printer") ] + supplies) ]
      end

      def read(device)
        slots = device.points.filter_map { |p| p.address["field"].to_s[/\Asupply_(\d)\z/, 1] }
        v = snmp(device.integration, [ PAGES, STATUS ] + slots.flat_map { |n| [ "#{SUPPLY}.8.1.#{n}", "#{SUPPLY}.9.1.#{n}" ] })
        out = { "pages" => v[PAGES], "status" => (text("states.#{v[STATUS]}") if v[STATUS]) }
        slots.each { |n| out["supply_#{n}"] = level(v["#{SUPPLY}.9.1.#{n}"], v["#{SUPPLY}.8.1.#{n}"]) }
        out
      end

      # Printer MIB: nível -3 = "tem um pouco" (sem medida), -2 = desconhecido; capacidade ≤ 0 = sem conta.
      def level(level, max)
        return 10 if level == -3
        return nil unless level.is_a?(Integer) && level >= 0 && max.is_a?(Integer) && max.positive?

        (100.0 * level / max).round
      end
    end
  end
end
