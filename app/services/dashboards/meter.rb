module Dashboards
  # Gás e água (ondaB2 B12; as fontes de gás e água do painel de energia do
  # HA): o mesmo cálculo do `Energy` (acumulado do medidor pelos rollups de
  # hora, período, projeção, meta, comparação e tarifa), em m³. Litros viram
  # m³. As chaves do resultado seguem as do Energy (`kwh` = quantidade).
  class Meter < Energy
    def self.volume?(p) = p.unit.to_s.strip.match?(/\A(m³|m3|l)\z/i) || p.device_class.in?(%w[gas water])
    def self.energy?(p) = volume?(p)
    def self.power?(_p) = false
    def self.supported?(p) = p.numeric? && volume?(p)

    private

    def factor(p) = p.unit.to_s.strip.casecmp?("l") ? 0.001 : 1.0
  end
end
