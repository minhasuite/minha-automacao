module Integrations
  # IKEA Dirigera (integ2): hub da IKEA pela API local (Drivers::Dirigera).
  # Sem token, o "Adicionar" pareia pelo botão de ação do hub (dois passos).
  class DirigeraPlugin < LanPlugin
    describe key: "dirigera", title: "IKEA Dirigera", icon: "light-bulb",
             description: "Lâmpadas, tomadas, persianas, purificadores e sensores IKEA pelo hub Dirigera da rede (API local, sem nuvem)."
    texts en: { title: "IKEA Dirigera", description: "IKEA bulbs, plugs, blinds, air purifiers and sensors through the Dirigera hub on your network (local API, no cloud)." },
          es: { title: "IKEA Dirigera", description: "Bombillas, enchufes, persianas, purificadores y sensores IKEA mediante el hub Dirigera de la red (API local, sin nube)." }
    port 8443
    secrets :token
    mdns "_ihsp._tcp"

    def self.inventory(integration) = Drivers::Dirigera.inventory(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
