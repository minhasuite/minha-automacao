module Integrations
  # Sonos (integ2): caixa Sonos da rede pela UPnP local (Drivers::Sonos). Achada por mDNS (_sonos._tcp).
  class SonosPlugin < MediaLanPlugin
    describe key: "sonos", title: "Sonos", icon: "volume-up",
             description: "Caixas Sonos da rede de casa, sem nuvem: o que está tocando, volume, mudo, tocar, pausar, avançar e tocar um endereço."
    port Drivers::Sonos::PORT
    mdns "_sonos._tcp"

    def self.probe(integration)
      d = Drivers::Sonos.description(host_of(integration), port_of(integration))
      Drivers::MediaLan.entry(integration, "sonos:#{d['udn'].presence || host_of(integration)}", kind: "sonos", supports: Drivers::Sonos::SUPPORTS,
                                                                                                 port: port_of(integration), manufacturer: "Sonos", model: d["model"], name: d["room"])
    end
  end
end
