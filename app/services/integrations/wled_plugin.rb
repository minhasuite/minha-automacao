module Integrations
  # WLED (integ): fita/painel de LED da rede pela JSON API (Drivers::Wled).
  class WledPlugin < LanPlugin
    describe key: "wled", title: "WLED", icon: "light-bulb",
             description: "Fitas e painéis de LED com WLED na rede de casa: liga, brilho, cor e efeitos, direto no aparelho."
    texts en: { title: "WLED", description: "LED strips and panels running WLED on your home network: power, brightness, color and effects, straight on the device." },
          es: { title: "WLED", description: "Tiras y paneles LED con WLED en la red de casa: encendido, brillo, color y efectos, directo en el aparato." }
    port 80
    mdns "_wled._tcp"

    def self.probe(integration) = Drivers::Wled.entry(integration)
  end
end
