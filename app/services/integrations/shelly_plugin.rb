module Integrations
  # Shelly da rede de casa (Pacote 1): relé, luz/dimmer, persiana e medição,
  # Gen1 (HTTP) e Gen2+ (RPC). Uma integração por aparelho; a senha só se ele
  # tiver autenticação ligada.
  class ShellyPlugin < LanPlugin
    describe key: "shelly", title: "Shelly", icon: "lightning-bolt",
             description: "Relés, dimmers, persianas e medidores Shelly da rede de casa (Gen1 e Plus/Pro). Lê consumo e energia; comando direto no aparelho."
    port 80
    secrets :password
    mdns "_shelly._tcp"

    def self.probe(integration) = Shelly.inventory_entry(integration)
  end
end
