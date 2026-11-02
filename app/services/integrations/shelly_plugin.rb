module Integrations
  # Shelly da rede de casa (Pacote 1): relé, luz/dimmer, persiana e medição,
  # Gen1 (HTTP) e Gen2+ (RPC). Uma integração por aparelho; a senha só se ele
  # tiver autenticação ligada.
  class ShellyPlugin < LanPlugin
    describe key: "shelly", title: "Shelly", icon: "lightning-bolt",
             description: "Relés, dimmers, persianas e medidores Shelly da rede de casa (Gen1 e Plus/Pro). Lê consumo e energia; comando direto no aparelho."
    texts en: { title: "Shelly", description: "Shelly relays, dimmers, shutters and meters on your home network (Gen1 and Plus/Pro). Reads power and energy; commands go straight to the device." },
          es: { title: "Shelly", description: "Relés, dimmers, persianas y medidores Shelly de la red de casa (Gen1 y Plus/Pro). Lee consumo y energía; el comando va directo al aparato." }
    port 80
    secrets :password
    mdns "_shelly._tcp"

    def self.probe(integration) = Shelly.inventory_entry(integration)
  end
end
