module Integrations
  # SmartThings (catalogo): aparelhos da conta Samsung SmartThings pela API
  # REST (OAuth do app SmartApp do dono). Cada capacidade conhecida vira um
  # ponto pelo mapa `config/device_maps/smartthings.yml` (capacidade nova =
  # bloco no mapa, sem código); comando pela mesma capacidade.
  class SmartthingsPlugin < OauthPlugin
    describe key: "smartthings", title: "SmartThings", icon: "home",
             description: "Aparelhos da conta Samsung SmartThings: tomadas, luzes, sensores de porta, movimento, vazamento, temperatura e energia, com liga/desliga e brilho."
    texts "pt-BR" => { note: "Crie o app (SmartApp do tipo API_ONLY) com a SmartThings CLI e informe o Client ID e o secret dele. Passo a passo em docs/catalogo.md." },
          en: { title: "SmartThings", description: "Devices on your Samsung SmartThings account: plugs, lights, door, motion, leak, temperature and energy sensors, with on/off and brightness.",
                note: "Create the app (an API_ONLY SmartApp) with the SmartThings CLI and enter its Client ID and secret. Step by step in docs/catalogo.md." },
          es: { title: "SmartThings", description: "Aparatos de la cuenta Samsung SmartThings: enchufes, luces, sensores de puerta, movimiento, fugas, temperatura y energía, con encendido y brillo.",
                note: "Crea la app (SmartApp del tipo API_ONLY) con la SmartThings CLI e indica su Client ID y secret. Paso a paso en docs/catalogo.md." }
    oauth authorize: "https://api.smartthings.com/oauth/authorize", token: "https://auth-global.api.smartthings.com/oauth/token",
          scope: "r:devices:* x:devices:* r:locations:*"
    API = "https://api.smartthings.com/v1".freeze

    class << self
      def map = (@map ||= YAML.load_file(Rails.root.join("config/device_maps/smartthings.yml")).freeze)

      # Cômodos de todos os locais da conta (id → nome) para sugerir a área.
      def rooms(integration)
        Array(api(integration, :get, "#{API}/locations")["items"]).flat_map do |l|
          Array(api(integration, :get, "#{API}/locations/#{l['locationId']}/rooms")["items"])
        end.to_h { |r| [ r["roomId"], r["name"] ] }
      rescue Integrations::Error
        {}
      end

      def entries(integration)
        rooms = rooms(integration)
        Array(api(integration, :get, "#{API}/devices")["items"]).filter_map do |d|
          caps = Array(d["components"]).find { |c| c["id"] == "main" }.to_h["capabilities"].to_a.map { |c| c["id"] }
          pts = caps.filter_map do |cap|
            m = map[cap] or next
            point(cap, m["capability"], name: m.dig("name", I18n.locale.to_s) || m.dig("name", "pt-BR"),
                  **m.slice("unit", "device_class", "state_class", "icon").symbolize_keys, **(m["capability"] == "dimmer" ? { min: 0, max: 100 } : {}))
          end
          next if pts.empty?

          entry(id: "smartthings:#{d['deviceId']}", name: d["label"].presence || d["name"], manufacturer: d["manufacturerName"].presence || "SmartThings",
                model: d["deviceTypeName"] || d.dig("ocf", "modelNumber"), room: rooms[d["roomId"]], address: { "device_id" => d["deviceId"] }, poll_s: 60, points: pts)
        end
      end

      def read(device)
        main = api(device.integration, :get, "#{API}/devices/#{device.address['device_id']}/status").dig("components", "main").to_h
        device.points.to_h do |p|
          cap = p.address["field"]
          m = map[cap].to_h
          attr = main.dig(cap, m["attribute"]).to_h
          v = attr["value"]
          v = v == m["truthy"] if m["truthy"] && !v.nil?
          v = ((v.to_f - 32) * 5 / 9).round(1) if attr["unit"] == "F" && v.is_a?(Numeric)
          [ cap, v ]
        end
      end

      def write(point, value)
        m = map[cap = point.address["field"]].to_h
        cmd = m["set"] ? { capability: cap, command: m["set"], arguments: [ value.to_i ] } : { capability: cap, command: value ? m["cmd_on"] : m["cmd_off"] }
        api(point.device.integration, :post, "#{API}/devices/#{point.device.address['device_id']}/commands", { commands: [ cmd.merge(component: "main") ] })
      end
    end
  end
end
