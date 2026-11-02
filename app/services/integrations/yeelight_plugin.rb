module Integrations
  # Yeelight (integ): lâmpada/fita pela LAN, com o Controle pela LAN ligado no app (Drivers::Yeelight).
  class YeelightPlugin < LanPlugin
    describe key: "yeelight", title: "Yeelight", icon: "light-bulb",
             description: "Lâmpadas e fitas Yeelight pela rede de casa (Controle pela LAN): liga, brilho e cor, sem nuvem."
    texts en: { title: "Yeelight", description: "Yeelight bulbs and strips over your home network (LAN Control): power, brightness and color, no cloud." },
          es: { title: "Yeelight", description: "Bombillas y tiras Yeelight por la red de casa (Control por LAN): encendido, brillo y color, sin nube." }
    port Drivers::Yeelight::PORT

    def self.probe(integration) = Drivers::Yeelight.entry(integration)
  end
end
