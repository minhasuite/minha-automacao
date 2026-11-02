module Integrations
  # Philips Hue (integ): Hue Bridge pela API v2 local (Drivers::Hue). Sem
  # chave, o primeiro "Adicionar" pareia (botão do bridge apertado antes).
  class HuePlugin < LanPlugin
    describe key: "hue", title: "Philips Hue", icon: "light-bulb",
             description: "Lâmpadas, fitas e sensores Hue pelo Hue Bridge da rede (API v2 local, sem nuvem): liga, brilho, cor, movimento e temperatura."
    texts en: { title: "Philips Hue", description: "Hue bulbs, strips and sensors through the Hue Bridge on your network (local API v2, no cloud): power, brightness, color, motion and temperature." },
          es: { title: "Philips Hue", description: "Bombillas, tiras y sensores Hue mediante el Hue Bridge de la red (API v2 local, sin nube): encendido, brillo, color, movimiento y temperatura." }
    port 443
    secrets :app_key
    mdns "_hue._tcp"

    def self.inventory(integration) = Drivers::Hue.inventory(integration)
  end
end
