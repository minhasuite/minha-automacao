module Integrations
  # Yeelight (integ): lâmpada/fita pela LAN, com o Controle pela LAN ligado no app (Drivers::Yeelight).
  class YeelightPlugin < LanPlugin
    describe key: "yeelight", title: "Yeelight", icon: "light-bulb",
             description: "Lâmpadas e fitas Yeelight pela rede de casa (Controle pela LAN): liga, brilho e cor, sem nuvem."
    port Drivers::Yeelight::PORT

    def self.probe(integration) = Drivers::Yeelight.entry(integration)
  end
end
