module Integrations
  # Daikin (integ2): AC com adaptador Wi-Fi BRP069/BRP072 pela API HTTP local (Drivers::Daikin).
  class DaikinPlugin < LanPlugin
    describe key: "daikin", title: "Daikin", icon: "sun",
             description: "Ar-condicionado Daikin com adaptador Wi-Fi na rede de casa: liga, modo, temperatura alvo, ventilação e temperatura ambiente, sem nuvem."
    port 80

    def self.probe(integration) = Drivers::Daikin.entry(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
