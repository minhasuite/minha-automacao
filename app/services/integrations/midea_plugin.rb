module Integrations
  # Midea (integ2): AC Midea e marcas do grupo pela rede local, protocolo V3
  # (Midea::Session). Token e chave do aparelho cifrados; o id às claras.
  class MideaPlugin < LanPlugin
    describe key: "midea", title: "Midea", icon: "sun",
             description: "Ar-condicionado Midea, Springer Midea, Comfee e Carrier com Wi-Fi, direto na rede de casa (protocolo local V3): liga, modo, temperatura e ventilação."
    port ::Midea::PORT
    secrets :token, :key
    plain :device_id

    def self.probe(integration) = Drivers::Midea.entry(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
