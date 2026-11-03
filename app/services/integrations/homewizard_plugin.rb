module Integrations
  # HomeWizard Energy (catalogo): medidor P1, kWh, tomada e medidor de água
  # pela API local v1 (`/api`, `/api/v1/data`, `/api/v1/state`; ligar "API
  # local" no app). Leitura a cada 10 s; a tomada liga e desliga.
  class HomewizardPlugin < SchemaPlugin
    describe key: "homewizard", title: "HomeWizard Energy", icon: "lightning-bolt",
             description: "Medidores HomeWizard (P1, kWh, tomada e água) na rede de casa: potência, energia importada e exportada, gás, água e a tomada liga/desliga."
    texts "pt-BR" => { points: { import: "Energia importada", export: "Energia exportada", gas: "Gás", water: "Água", water_flow: "Vazão de água" },
                       note: "No app HomeWizard: Configurações → Medidores → o aparelho → API local (ligar)." },
          en: { title: "HomeWizard Energy", description: "HomeWizard meters (P1, kWh, socket and water) on your home network: power, imported and exported energy, gas, water and switching the socket.",
                points: { import: "Energy imported", export: "Energy exported", gas: "Gas", water: "Water", water_flow: "Water flow" },
                note: "In the HomeWizard app: Settings → Meters → the device → Local API (turn on)." },
          es: { title: "HomeWizard Energy", description: "Medidores HomeWizard (P1, kWh, enchufe y agua) en la red de casa: potencia, energía importada y exportada, gas, agua y el enchufe encendido/apagado.",
                points: { import: "Energía importada", export: "Energía exportada", gas: "Gas", water: "Agua", water_flow: "Caudal de agua" },
                note: "En la app HomeWizard: Configuración → Medidores → el aparato → API local (activar)." }
    field :host, required: true
    mdns "_hwenergy._tcp"

    # Campo da API → ponto.
    DATA = {
      "active_power_w" => [ "power", { unit: "W", device_class: "power", state_class: "measurement" } ],
      "total_power_import_kwh" => [ "import", { unit: "kWh", device_class: "energy", state_class: "total_increasing" } ],
      "total_power_export_kwh" => [ "export", { unit: "kWh", device_class: "energy", state_class: "total_increasing" } ],
      "active_voltage_v" => [ "voltage", { unit: "V", device_class: "voltage", state_class: "measurement" } ],
      "active_current_a" => [ "current", { unit: "A", device_class: "current", state_class: "measurement" } ],
      "total_gas_m3" => [ "gas", { unit: "m³", device_class: "gas", state_class: "total_increasing" } ],
      "total_liter_m3" => [ "water", { unit: "m³", device_class: "water", state_class: "total_increasing" } ],
      "active_liter_lpm" => [ "water_flow", { unit: "L/min", state_class: "measurement" } ]
    }.freeze

    class << self
      def base(host) = LanHttp.base(host)

      def entries(integration)
        host = conf(integration, :host)
        info = LanHttp.get("#{base(host)}/api")
        data = LanHttp.get("#{base(host)}/api/v1/data")
        socket = info["product_type"] == "HWE-SKT"
        pts = DATA.filter_map { |k, (f, o)| point(f, **o) if data.key?(k) }
        pts.unshift(point("switch", "onoff", icon: "power")) if socket
        [ entry(id: "homewizard:#{info['serial'].presence || host}", name: info["product_name"].presence || title, model: info["product_type"],
                category: "API #{info['api_version']}", address: { "host" => host }, poll_s: 10, points: pts) ]
      end

      def read(device)
        data = LanHttp.get("#{base(device.address['host'])}/api/v1/data")
        out = DATA.to_h { |k, (f, _)| [ f, data[k] ] }
        out["switch"] = LanHttp.get("#{base(device.address['host'])}/api/v1/state")["power_on"] if device.points.any? { |p| p.address["field"] == "switch" }
        out
      end

      def write(point, value) = LanHttp.call(:put, "#{base(point.device.address['host'])}/api/v1/state", body: { power_on: value == true })
    end
  end
end
