module Integrations
  # IKEA Dirigera (integ2): hub da IKEA pela API local (Drivers::Dirigera).
  # Sem token, o "Adicionar" pareia pelo botão de ação do hub (dois passos).
  class DirigeraPlugin < LanPlugin
    describe key: "dirigera", title: "IKEA Dirigera", icon: "light-bulb",
             description: "Lâmpadas, tomadas, persianas, purificadores e sensores IKEA pelo hub Dirigera da rede (API local, sem nuvem)."
    port 8443
    secrets :token
    mdns "_ihsp._tcp"

    def self.inventory(integration) = Drivers::Dirigera.inventory(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
