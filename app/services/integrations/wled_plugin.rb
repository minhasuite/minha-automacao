module Integrations
  # WLED (integ): fita/painel de LED da rede pela JSON API (Drivers::Wled).
  class WledPlugin < LanPlugin
    describe key: "wled", title: "WLED", icon: "light-bulb",
             description: "Fitas e painéis de LED com WLED na rede de casa: liga, brilho, cor e efeitos, direto no aparelho."
    port 80
    mdns "_wled._tcp"

    def self.probe(integration) = Drivers::Wled.entry(integration)
  end
end
