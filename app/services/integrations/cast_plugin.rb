module Integrations
  # Chromecast / Google Cast (Pacote 1): o que toca, volume e controles pelo
  # protocolo CastV2 na rede (Drivers::Cast). Achado por mDNS (_googlecast._tcp).
  class CastPlugin < MediaLanPlugin
    describe key: "cast", title: "Chromecast / Google Cast", icon: "desktop-computer",
             description: "Chromecast, Google TV e caixas com Google Cast da rede: o que está tocando, volume, pausar e tocar um endereço."
    texts en: { title: "Chromecast / Google Cast", description: "Chromecast, Google TV and Google Cast boxes on your network: what's playing, volume, pause and play a URL." },
          es: { title: "Chromecast / Google Cast", description: "Chromecast, Google TV y cajas con Google Cast de la red: lo que se reproduce, volumen, pausa y reproducir una dirección." }
    port Drivers::Cast::PORT
    mdns "_googlecast._tcp"

    def self.probe(integration)
      host = host_of(integration)
      Drivers::Cast::Client.new(host, port_of(integration)).session { |c| Drivers::Cast.state(c) }
      Drivers::MediaLan.entry(integration, "cast:#{host}", kind: "cast", supports: Drivers::Cast::SUPPORTS, port: port_of(integration), manufacturer: "Google")
    end
  end
end
