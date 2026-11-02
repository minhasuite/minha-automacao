module Integrations
  # Inversor solar SunSpec (integ2): qualquer inversor com SunSpec por
  # Modbus TCP na rede de casa (Drivers::Sunspec), só leitura.
  class SunspecPlugin < LanPlugin
    describe key: "sunspec", title: "Inversor solar (SunSpec / Modbus)", icon: "sun",
             description: "Inversores com SunSpec por Modbus TCP na rede (Fronius, SMA, SolarEdge, Huawei, WEG e outros): potência, energia gerada, tensão e estado, para os painéis de energia."
    texts en: { title: "Solar inverter (SunSpec / Modbus)", description: "Inverters with SunSpec over Modbus TCP on your network (Fronius, SMA, SolarEdge, Huawei, WEG and others): power, energy produced, voltage and status, for the energy dashboards." },
          es: { title: "Inversor solar (SunSpec / Modbus)", description: "Inversores con SunSpec por Modbus TCP en la red (Fronius, SMA, SolarEdge, Huawei, WEG y otros): potencia, energía generada, tensión y estado, para los paneles de energía." }
    port 502
    plain :unit

    def self.probe(integration) = Drivers::Sunspec.entry(integration)
    def self.refresh(integration) = Drivers.refresh(integration)
  end
end
