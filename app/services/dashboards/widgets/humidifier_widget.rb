module Dashboards
  module Widgets
    # Umidificador (ondaB2 B10; o `humidifier` do HA): o mostrador do
    # termostato com o alvo de umidade, a umidade de agora e o modo.
    class HumidifierWidget < ThermostatWidget
      describe type: "humidifier", label: "Umidificador", icon: "beaker", required: %w[bind], bind: true
      texts en: { label: "Humidifier", target: "Target" }, es: { label: "Humidificador", target: "Objetivo" }, "pt-BR" => { target: "Alvo" }

      def self.target?(p) = TileFeatures::TargetHumidity.match?(p)
      def self.current?(p, _target) = p.capability == "measure" && (p.device_class == "humidity" || (p.unit.to_s == "%" && p.name.match?(/umid|humid/i)))
      def self.mode?(p) = TileFeatures::HumidifierMode.match?(p) || (p.capability == "enum" && p.name.match?(/\Amodo|mode/i))
      def self.default_range = [ 30, 80, 1 ]
      def self.tone(_mode, _point) = "humid"
    end
  end
end
