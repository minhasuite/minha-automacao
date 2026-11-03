module Dashboards
  module Widgets
    # Luz (ondaB2 B10; o `light` do HA): o mostrador com o brilho, a cor real
    # da lâmpada no anel e o toque no centro para acender ou apagar.
    class LightWidget < ThermostatWidget
      describe type: "light", label: "Luz", icon: "light-bulb", required: %w[bind], bind: true
      texts en: { label: "Light", target: "Brightness" }, es: { label: "Luz", target: "Brillo" }, "pt-BR" => { target: "Brilho" }

      def self.target?(p) = TileFeatures::Brightness.match?(p)
      def self.current?(_p, _target) = false
      def self.mode?(_p) = false
      def self.default_range = [ 0, 100, 10 ]
      def self.tone(_mode, _point) = "light"

      def self.extra(r, data, around)
        color = r.use(around.find { |p| p.capability == "color" && !p.disabled })
        power = r.point(data["power_id"])
        on = power ? power.value == true : data["value"].to_f.positive?
        glow = Points::Color.hex_of(color.value) if color&.value.is_a?(Hash) && color.value["mode"] == "hs"
        data.merge("color_id" => color&.id, "glow" => glow, "unit" => data["unit"] || "%", "step" => 10.0, "on" => on, "tone" => on ? "light" : "off")
      end
    end
  end
end
