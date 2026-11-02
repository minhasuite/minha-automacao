module Integrations
  # Inversor solar SunSpec (integ2): qualquer inversor com SunSpec por
  # Modbus TCP na rede de casa (Drivers::Sunspec), só leitura.
  class SunspecPlugin < LanPlugin
    describe key: "sunspec", title: "Inversor solar (SunSpec / Modbus)", icon: "sun",
             description: "Inversores com SunSpec por Modbus TCP na rede (Fronius, SMA, SolarEdge, Huawei, WEG e outros): potência, energia gerada, tensão e estado, para os painéis de energia."
    port 502
    plain :unit

    def self.probe(integration) = Drivers::Sunspec.entry(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
