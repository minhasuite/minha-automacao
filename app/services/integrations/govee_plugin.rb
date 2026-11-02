module Integrations
  # Govee (integ2): lâmpadas e fitas pela API LAN (UDP) da Govee (Drivers::Govee).
  # "Procurar na rede" usa o scan multicast próprio da Govee (não é mDNS).
  class GoveePlugin < LanPlugin
    describe key: "govee", title: "Govee", icon: "light-bulb",
             description: "Lâmpadas e fitas Govee com Controle LAN ligado no app: liga, brilho e cor, direto na rede de casa, sem nuvem."
    port Drivers::Govee::PORT

    def self.discovers? = true
    def self.discover = Drivers::Govee.discover
    def self.probe(integration) = Drivers::Govee.entry(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
