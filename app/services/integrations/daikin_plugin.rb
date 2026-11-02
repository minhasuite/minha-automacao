module Integrations
  # Daikin (integ2): AC com adaptador Wi-Fi BRP069/BRP072 pela API HTTP local (Drivers::Daikin).
  class DaikinPlugin < LanPlugin
    describe key: "daikin", title: "Daikin", icon: "sun",
             description: "Ar-condicionado Daikin com adaptador Wi-Fi na rede de casa: liga, modo, temperatura alvo, ventilação e temperatura ambiente, sem nuvem."
    texts en: { title: "Daikin", description: "Daikin air conditioners with a Wi-Fi adapter on your home network: power, mode, target temperature, fan and room temperature, no cloud." },
          es: { title: "Daikin", description: "Aires acondicionados Daikin con adaptador Wi-Fi en la red de casa: encendido, modo, temperatura objetivo, ventilación y temperatura ambiente, sin nube." }
    port 80

    def self.probe(integration) = Drivers::Daikin.entry(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
