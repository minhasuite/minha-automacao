module Dashboards
  module Widgets
    # Termostato (ondaB2 B10; o `thermostat` do HA): mostrador com o alvo,
    # a temperatura de agora, −/+ e os modos. O ponto do card pode ser qualquer
    # um do aparelho (ar, aquecedor): alvo, medida, modo e liga/desliga saem
    # dos irmãos. Umidificador e luz herdam e trocam só as regras do alvo
    # (`target?`, `current?`, `mode?`); os três usam o partial `_dial`.
    class ThermostatWidget < Base
      describe type: "thermostat", label: "Termostato", icon: "thermometer", required: %w[bind], bind: true
      texts en: { label: "Thermostat", target: "Target" }, es: { label: "Termostato", target: "Objetivo" }, "pt-BR" => { target: "Alvo" }

      TONES = { "heat" => /aquec|heat|quente/i, "cool" => /refrig|cool|frio/i, "dry" => /desumid|\bdry\b|seco/i, "fan" => /ventil|\bfan\b/i }.freeze

      def self.target?(p) = p.capability == "setpoint" && TileFeatures::TargetTemperature.match?(p)
      def self.current?(p, target) = p.capability == "measure" && (p.device_class.present? ? p.device_class == target.device_class : p.unit == target.unit)
      def self.mode?(p) = TileFeatures::ClimateMode.match?(p)
      def self.default_range = [ 16, 30, 0.5 ]
      def self.tone(mode, _point) = TONES.find { |_, re| mode.to_s.match?(re) }&.first || "auto"

      def self.partial = "web/dashboards/widgets/dial"
      def self.permit = super + [ { "features" => [] } ]

      def self.data(r, w, binds)
        point = binds.first or return [ { "point_ids" => [], "missing" => w["bind"].present? }, [] ]

        around = [ point, *TileFeatures.siblings(r, point) ]
        target = around.find { |p| target?(p) }
        power = around.find { |p| p.capability == "onoff" }
        return [ { "point_ids" => [ point.id ], "missing" => true }, [] ] unless target || power

        current = target && around.find { |p| p != target && current?(p, target) }
        mode = around.find { |p| mode?(p) }
        [ current, mode, power, target ].compact.each { |p| r.use(p) }
        min, max, step = default_range
        min = target&.min&.to_f || min
        max = target&.max&.to_f || max
        value = target&.value
        on = power.nil? || power.value == true
        features, used = TileFeatures.resolve(r, w, point)
        data = { "point_ids" => [ (target || power).id ], "target_id" => target&.id, "current_id" => current&.id, "mode_id" => mode&.id, "power_id" => power&.id,
                 "title" => w["label"].presence || point.device.name, "value" => value, "current" => current&.value, "unit" => target&.unit || current&.unit,
                 "min" => min, "max" => max, "step" => target&.step&.to_f || step, "on" => on, "target_label" => text(:target),
                 "ratio" => value.is_a?(Numeric) && max > min ? ((value - min) / (max - min)).clamp(0, 1).round(3) : (on ? 1 : 0),
                 "tone" => on ? tone(mode&.value, point) : "off", "modes" => (Array(mode.options) if mode), "mode" => mode&.value,
                 "features" => features.presence }
        data = extra(r, data, around).compact
        [ data, used + [ current, mode, power, target, r.point(data["color_id"]) ].compact ]
      end

      # Gancho dos herdeiros (a luz põe a cor real).
      def self.extra(_r, data, _around) = data
    end
  end
end
