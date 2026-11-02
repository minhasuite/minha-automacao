# Unidades (ondaA1, A4; o sistema de unidades do HA): conversão para mostrar
# o valor na unidade do local (métrico/imperial) ou na escolhida para o
# ponto (`points.display_unit`). O valor guardado não muda (histórico,
# automações e pontes seguem na unidade do aparelho).
#
# Grandeza nova = linha em DIMENSIONS: unidade → [fator, deslocamento] sobre
# a unidade base (valor_base = v * fator + deslocamento). Sistema novo =
# entrada em SYSTEMS (unidade → a preferida do sistema).
module Units
  DIMENSIONS = {
    "temperature" => { "°C" => [ 1, 0 ], "°F" => [ 5.0 / 9, -160.0 / 9 ], "K" => [ 1, -273.15 ] },
    "length" => { "m" => [ 1, 0 ], "cm" => [ 0.01, 0 ], "mm" => [ 0.001, 0 ], "km" => [ 1000, 0 ], "in" => [ 0.0254, 0 ], "ft" => [ 0.3048, 0 ], "mi" => [ 1609.344, 0 ] },
    "speed" => { "m/s" => [ 1, 0 ], "km/h" => [ 1 / 3.6, 0 ], "mph" => [ 0.44704, 0 ], "kn" => [ 0.514444, 0 ] },
    "pressure" => { "hPa" => [ 1, 0 ], "kPa" => [ 10, 0 ], "bar" => [ 1000, 0 ], "mbar" => [ 1, 0 ], "psi" => [ 68.9476, 0 ], "inHg" => [ 33.8639, 0 ], "mmHg" => [ 1.33322, 0 ] },
    "volume" => { "L" => [ 1, 0 ], "mL" => [ 0.001, 0 ], "m³" => [ 1000, 0 ], "gal" => [ 3.78541, 0 ], "ft³" => [ 28.3168, 0 ] },
    "mass" => { "kg" => [ 1, 0 ], "g" => [ 0.001, 0 ], "lb" => [ 0.453592, 0 ], "oz" => [ 0.0283495, 0 ] },
    "energy" => { "kWh" => [ 1, 0 ], "Wh" => [ 0.001, 0 ], "MWh" => [ 1000, 0 ] },
    "power" => { "W" => [ 1, 0 ], "kW" => [ 1000, 0 ] }
  }.freeze

  SYSTEMS = {
    "metric" => { label: "Métrico (°C, km, L, kg)", prefer: { "°F" => "°C", "in" => "mm", "ft" => "m", "mi" => "km", "mph" => "km/h", "psi" => "kPa", "inHg" => "hPa", "gal" => "L", "ft³" => "m³", "lb" => "kg", "oz" => "g" } },
    "imperial" => { label: "Imperial (°F, mi, gal, lb)", prefer: { "°C" => "°F", "mm" => "in", "cm" => "in", "m" => "ft", "km" => "mi", "km/h" => "mph", "m/s" => "mph", "kPa" => "psi", "hPa" => "inHg", "L" => "gal", "m³" => "ft³", "kg" => "lb", "g" => "oz" } }
  }.freeze

  module_function

  def dimension_of(unit) = DIMENSIONS.find { |_, units| units.key?(unit.to_s) }&.first

  # Unidades para as quais `unit` converte (a própria primeiro); [] se não converte.
  def compatible(unit)
    dim = dimension_of(unit) or return []
    [ unit, *(DIMENSIONS[dim].keys - [ unit ]) ]
  end

  def convert(value, from, to)
    return value if from == to || !value.is_a?(Numeric)

    dim = dimension_of(from)
    return value unless dim && DIMENSIONS[dim].key?(to)

    f1, o1 = DIMENSIONS[dim][from]
    f2, o2 = DIMENSIONS[dim][to]
    ((value * f1) + o1 - o2) / f2
  end

  # Unidade de exibição: a do ponto, senão a preferida do sistema do local, senão a do aparelho.
  def display_unit(point)
    return point.unit if dimension_of(point.unit).nil?
    return point.display_unit if point.display_unit.present? && compatible(point.unit).include?(point.display_unit)

    pref = SYSTEMS.dig(system_for(point.site_id), :prefer, point.unit.to_s)
    pref && compatible(point.unit).include?(pref) ? pref : point.unit
  end

  def system_for(site_id) = (Current.unit_systems ||= {})[site_id] ||= Site.where(id: site_id).pick(:unit_system).presence || "metric"

  # [valor convertido, unidade] para mostrar.
  def for_display(point, value = point.value)
    unit = display_unit(point)
    [ convert(value, point.unit, unit), unit ]
  end
end
