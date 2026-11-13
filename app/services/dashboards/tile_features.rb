module Dashboards
  # Recursos do tile (ondaB2 B9; as "tile features" do HA), por registro como
  # os widgets: recurso novo = classe que herda de `Base` (aqui ou num arquivo
  # próprio) + nome em `PLUGINS`. No JSON do tile:
  #
  #   "features": [ "brightness", { "type": "climate_mode", "point": "<id ou chave>" } ]
  #
  # Sem `point`, o recurso acha o alvo no próprio ponto do tile ou num irmão
  # do mesmo aparelho (o MA guarda um aparelho em vários pontos: o ar tem
  # liga/desliga, alvo, modo e ventilação). O recurso não desenha: diz o
  # `kind` (toggle, slider, stepper, chips, buttons, trend, bar) e o payload;
  # a web (`web/dashboards/features/_<kind>`) e o app (`TileFeatureRegistry`)
  # desenham cada kind. `toggle`/`select`/`slider` (antigos) seguem sendo os
  # controles próprios do tile.
  module TileFeatures
    LEGACY = %w[toggle select slider].freeze
    MAX = 6
    PLUGINS = %w[Power Brightness ColorTemp LightColors CoverOpenClose CoverPosition CoverTilt FanSpeed FanOscillate FanDirection FanPreset
                 ClimateMode ClimateFan ClimatePreset ClimateSwing TargetTemperature TargetHumidity HumidifierMode WaterHeaterMode
                 VacuumCommands AlarmModes LockCommands ValveOpenClose SelectOptions NumericInput MediaVolume MediaPlayback
                 CounterActions PressButton TrendGraph BarGauge].freeze

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |f| f.key == key.to_s }

    # [[chave, ref do ponto ou nil]] dos recursos novos (os antigos ficam de fora).
    def entries(list)
      Array(list).filter_map do |f|
        key, ref = f.is_a?(Hash) ? [ f["type"], f["point"] ] : [ f, nil ]
        [ key.to_s, ref.presence ] unless LEGACY.include?(key.to_s)
      end
    end

    def errors(list)
      return [ I18n.t("dashboards.schema.features_list", max: MAX + LEGACY.size) ] unless list.is_a?(Array) && list.size <= MAX + LEGACY.size

      list.filter_map do |f|
        key = f.is_a?(Hash) ? f["type"] : f
        next I18n.t("dashboards.schema.feature_object") if f.is_a?(Hash) && !((f.keys - %w[type point]).empty? && (f["point"].nil? || f["point"].is_a?(String)))
        next if LEGACY.include?(key) || self[key]

        I18n.t("dashboards.schema.feature_unknown", key: key.inspect)
      end
    end

    # Irmãos do ponto (mesmo aparelho, à vista) para achar o alvo.
    def siblings(r, point) = r.device_points(point.device_id).select { |p| p.id != point.id && !p.hidden && !p.disabled }

    # Payload dos recursos do tile → [lista, pontos usados]. Recurso sem alvo some.
    def resolve(r, w, point)
      return [ [], [] ] unless point

      around = siblings(r, point)
      used = []
      list = entries(w["features"]).filter_map do |key, ref|
        plugin = self[key] or next
        target = ref ? r.point(ref) : plugin.target(point, around)
        next unless target && plugin.match?(target)

        used << r.use(target)
        { "type" => key, "kind" => plugin.kind, "label" => plugin.label, "icon" => plugin.icon, "point_id" => target.id }.merge(plugin.payload(target, r))
      end
      [ list.first(MAX), used ]
    end

    # Recursos que servem a este tile (editor): os que acham alvo.
    def available(point, around) = point ? plugins.select { |f| f.target(point, around) } : []

    COVER = DashboardsHelper::COVER
    FAN = DashboardsHelper::FAN
    def named?(p, re) = "#{p.name} #{p.device&.name} #{p.address['role']} #{p.address['field']}".match?(re)
    def range(p, min = 0, max = 100) = { "min" => p.min || min, "max" => p.max || max, "step" => p.step || 1 }
    def climate?(p) = p.device&.points&.any? { |s| s.capability.in?(%w[climate setpoint]) } || false

    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key, :icon, :kind

        # capabilities: capacidades do alvo; match: regra extra (lambda do ponto).
        def describe(key:, label:, icon:, kind:, capabilities:, match: nil)
          @key = key
          @label = label
          @icon = icon
          @kind = kind
          @capabilities = capabilities.freeze
          @match = match
        end

        def match?(p) = @capabilities.include?(p.capability) && !p.disabled && (@match.nil? || @match.call(p))
        def target(point, around) = [ point, *around ].find { |p| match?(p) }

        def partial = "web/dashboards/features/#{kind}"

        # Payload do kind (valor, faixa, opções ou botões).
        def payload(p, _r) = { "value" => p.value }

        def buttons(p, list)
          allowed = Points::Command.commands_for(p) + Points::Command.actions_for(p)
          { "buttons" => list.select { |b| allowed.include?(b["command"]) } }
        end
      end
    end

    class Power < Base
      describe key: "power", label: "Liga/desliga", icon: "power", kind: "toggle", capabilities: %w[onoff]
      texts en: { label: "On/off" }, es: { label: "Encender/apagar" }
    end

    class Brightness < Base
      describe key: "brightness", label: "Brilho", icon: "light-bulb", kind: "slider", capabilities: %w[dimmer],
               match: ->(p) { !TileFeatures.named?(p, COVER) && !TileFeatures.named?(p, FAN) }
      texts en: { label: "Brightness" }, es: { label: "Brillo" }
      def self.payload(p, _r) = TileFeatures.range(p).merge("value" => p.value, "command" => "set", "unit" => "%")
    end

    class ColorTemp < Base
      describe key: "color_temp", label: "Temperatura de cor", icon: "sun", kind: "slider", capabilities: %w[color]
      texts en: { label: "Color temperature" }, es: { label: "Temperatura de color" }

      def self.payload(p, _r)
        k = p.value.is_a?(Hash) && p.value["kelvin"].is_a?(Numeric) ? p.value["kelvin"] : 4000
        { "min" => 2000, "max" => 6500, "step" => 100, "value" => k, "command" => "set", "wrap" => "kelvin", "unit" => "K", "gradient" => "temp" }
      end
    end

    # Cores favoritas (o "light color favorites" do HA): seis tons prontos.
    class LightColors < Base
      COLORS = { "#ff9f43" => "Quente", "#ffffff" => "Branco", "#ff4d4d" => "Vermelho", "#3b82f6" => "Azul", "#22c55e" => "Verde", "#a855f7" => "Roxo" }.freeze
      describe key: "light_colors", label: "Cores favoritas", icon: "color-swatch", kind: "buttons", capabilities: %w[color]
      texts en: { label: "Favorite colors", c: { Quente: "Warm", Branco: "White", Vermelho: "Red", Azul: "Blue", Verde: "Green", Roxo: "Purple" } },
            es: { label: "Colores favoritos", c: { Quente: "Cálido", Branco: "Blanco", Vermelho: "Rojo", Azul: "Azul", Verde: "Verde", Roxo: "Morado" } },
            "pt-BR" => { c: COLORS.values.index_with { |v| v } }

      def self.payload(p, _r) = buttons(p, COLORS.map { |hex, name| { "command" => "set", "value" => hex, "label" => text("c.#{name}"), "swatch" => hex } })
    end

    class CoverOpenClose < Base
      describe key: "cover_open_close", label: "Abrir e fechar", icon: "switch-vertical", kind: "buttons", capabilities: %w[dimmer setpoint],
               match: ->(p) { TileFeatures.named?(p, COVER) && !TileFeatures.named?(p, /inclina|tilt|l[âa]mina/i) }
      texts en: { label: "Open and close", open: "Open", close: "Close" }, es: { label: "Abrir y cerrar", open: "Abrir", close: "Cerrar" },
            "pt-BR" => { open: "Abrir", close: "Fechar" }

      def self.payload(p, _r)
        buttons(p, [ { "command" => "set", "value" => p.max || 100, "label" => text(:open), "icon" => "chevron-up", "active" => p.value == (p.max || 100) },
                     { "command" => "set", "value" => p.min || 0, "label" => text(:close), "icon" => "chevron-down", "active" => p.value == (p.min || 0) } ])
      end
    end

    class CoverPosition < Base
      describe key: "cover_position", label: "Posição", icon: "adjustments", kind: "slider", capabilities: %w[dimmer setpoint],
               match: ->(p) { TileFeatures.named?(p, COVER) && !TileFeatures.named?(p, /inclina|tilt|l[âa]mina/i) }
      texts en: { label: "Position" }, es: { label: "Posición" }
      def self.payload(p, _r) = TileFeatures.range(p).merge("value" => p.value, "command" => "set", "unit" => "%")
    end

    class CoverTilt < Base
      describe key: "cover_tilt", label: "Inclinação", icon: "adjustments", kind: "slider", capabilities: %w[dimmer setpoint],
               match: ->(p) { TileFeatures.named?(p, /inclina|tilt|l[âa]mina/i) }
      texts en: { label: "Tilt" }, es: { label: "Inclinación" }
      def self.payload(p, _r) = TileFeatures.range(p).merge("value" => p.value, "command" => "set", "unit" => "%")
    end

    class FanSpeed < Base
      describe key: "fan_speed", label: "Velocidade", icon: "fan", kind: "slider", capabilities: %w[dimmer], match: ->(p) { TileFeatures.named?(p, FAN) }
      texts en: { label: "Speed" }, es: { label: "Velocidad" }
      def self.payload(p, _r) = TileFeatures.range(p).merge("value" => p.value, "command" => "set", "unit" => "%")
    end

    class FanOscillate < Base
      describe key: "fan_oscillate", label: "Oscilar", icon: "switch-horizontal", kind: "toggle", capabilities: %w[onoff], match: ->(p) { TileFeatures.named?(p, /oscil|swing/i) }
      texts en: { label: "Oscillate" }, es: { label: "Oscilar" }
    end

    # Escolha numa lista (enum): os vários "modos" do HA mudam só a regra do alvo.
    class Chips < Base
      def self.payload(p, _r) = { "options" => Array(p.options), "value" => p.value, "command" => "select" }
    end

    class FanDirection < Chips
      describe key: "fan_direction", label: "Direção", icon: "refresh", kind: "chips", capabilities: %w[enum], match: ->(p) { TileFeatures.named?(p, /dire[cç]|direction/i) }
      texts en: { label: "Direction" }, es: { label: "Dirección" }
    end

    class FanPreset < Chips
      describe key: "fan_preset", label: "Modo do ventilador", icon: "fan", kind: "chips", capabilities: %w[enum],
               match: ->(p) { "#{p.device&.name} #{p.name}".match?(FAN) && !TileFeatures.climate?(p) && !TileFeatures.named?(p, /dire[cç]|direction/i) }
      texts en: { label: "Fan mode" }, es: { label: "Modo del ventilador" }
    end

    class ClimateMode < Chips
      describe key: "climate_mode", label: "Modo do clima", icon: "sun", kind: "chips", capabilities: %w[enum],
               match: ->(p) { TileFeatures.climate?(p) && (p.address["field"] == "mode" || p.name.match?(/\Amodo|\bmode\b|hvac/i)) }
      texts en: { label: "Climate mode" }, es: { label: "Modo de clima" }
    end

    class ClimateFan < Chips
      describe key: "climate_fan", label: "Ventilação", icon: "fan", kind: "chips", capabilities: %w[enum],
               match: ->(p) { TileFeatures.climate?(p) && (p.address["field"] == "fan" || p.name.match?(/ventila|\bfan\b/i)) }
      texts en: { label: "Fan" }, es: { label: "Ventilación" }
    end

    class ClimatePreset < Chips
      describe key: "climate_preset", label: "Predefinição", icon: "star", kind: "chips", capabilities: %w[enum],
               match: ->(p) { TileFeatures.climate?(p) && (p.address["field"] == "preset" || p.name.match?(/preset|predefin|perfil/i)) }
      texts en: { label: "Preset" }, es: { label: "Preajuste" }
    end

    class ClimateSwing < Chips
      describe key: "climate_swing", label: "Aletas", icon: "switch-vertical", kind: "chips", capabilities: %w[enum],
               match: ->(p) { TileFeatures.climate?(p) && (p.address["field"] == "swing" || p.name.match?(/swing|aleta|oscila/i)) }
      texts en: { label: "Swing" }, es: { label: "Aletas" }
    end

    class Stepper < Base
      def self.payload(p, _r) = TileFeatures.range(p, nil, nil).merge("value" => p.value, "command" => "set", "unit" => p.unit)
    end

    class TargetTemperature < Stepper
      describe key: "target_temperature", label: "Temperatura alvo", icon: "thermometer", kind: "stepper", capabilities: %w[setpoint],
               match: ->(p) { p.device_class == "temperature" || p.unit.to_s.match?(/°\s?[CF]\z/) }
      texts en: { label: "Target temperature" }, es: { label: "Temperatura objetivo" }
      def self.payload(p, r) = super.merge("step" => p.step || 0.5)
    end

    class TargetHumidity < Stepper
      describe key: "target_humidity", label: "Umidade alvo", icon: "beaker", kind: "stepper", capabilities: %w[setpoint dimmer],
               match: ->(p) { p.device_class == "humidity" || (p.unit.to_s == "%" && TileFeatures.named?(p, /umid|humid/i)) }
      texts en: { label: "Target humidity" }, es: { label: "Humedad objetivo" }
    end

    class HumidifierMode < Chips
      describe key: "humidifier_mode", label: "Modo do umidificador", icon: "beaker", kind: "chips", capabilities: %w[enum], match: ->(p) { "#{p.device&.name} #{p.name}".match?(/umidific|humidif/i) }
      texts en: { label: "Humidifier mode" }, es: { label: "Modo del humidificador" }
    end

    class WaterHeaterMode < Chips
      describe key: "water_heater_mode", label: "Modo do aquecedor", icon: "fire", kind: "chips", capabilities: %w[enum], match: ->(p) { "#{p.device&.name} #{p.name}".match?(/aquecedor|boiler|water heater|termo ?acumul/i) }
      texts en: { label: "Water heater mode" }, es: { label: "Modo del calentador" }
    end

    class VacuumCommands < Base
      LIST = { "start" => %w[play Limpar], "pause" => %w[pause Pausar], "stop" => %w[stop Parar], "home" => %w[home Base], "locate" => %w[location-marker Localizar] }.freeze
      describe key: "vacuum_commands", label: "Comandos do robô", icon: "sparkles", kind: "buttons", capabilities: %w[vacuum]
      texts en: { label: "Vacuum commands", b: { Limpar: "Clean", Pausar: "Pause", Parar: "Stop", Base: "Dock", Localizar: "Locate" } },
            es: { label: "Comandos del robot", b: { Limpar: "Limpiar", Pausar: "Pausar", Parar: "Detener", Base: "Base", Localizar: "Localizar" } },
            "pt-BR" => { b: LIST.values.to_h { |(_, l)| [ l, l ] } }
      def self.payload(p, _r) = buttons(p, LIST.map { |c, (ico, l)| { "command" => c, "label" => text("b.#{l}"), "icon" => ico } })
    end

    # Modos do painel de alarme (helper alarm_panel). Painel que pede código
    # para armar fica no card de alarme (teclado).
    class AlarmModes < Base
      describe key: "alarm_modes", label: "Modos do alarme", icon: "shield-check", kind: "buttons", capabilities: %w[enum], match: ->(p) { p.helper == "alarm_panel" && p.address["code_arm"] != true }
      texts en: { label: "Alarm modes" }, es: { label: "Modos de alarma" }

      def self.payload(p, _r)
        plugin = HelperTypes::AlarmPanel
        list = plugin.configured(p).map { |s| { "command" => plugin::MODES[s][:command], "label" => plugin.mode_label(s), "active" => p.value == s } }
        disarm = Points::Command.commands_for(p).include?("disarm") ? [ { "command" => "disarm", "label" => plugin.text(:disarm), "icon" => "lock-open", "active" => p.value == "disarmed" } ] : []
        buttons(p, list + disarm)
      end
    end

    # Fechadura no MA = `gate` (pulso troca o estado), como na ponte Matter.
    class LockCommands < Base
      describe key: "lock_commands", label: "Fechadura", icon: "lock-closed", kind: "buttons", capabilities: %w[gate], match: ->(p) { TileFeatures.named?(p, /fechadura|tranca|\block\b/i) }
      texts en: { label: "Lock", lock: "Lock", unlock: "Unlock" }, es: { label: "Cerradura", lock: "Cerrar", unlock: "Abrir" },
            "pt-BR" => { lock: "Trancar", unlock: "Destrancar" }

      def self.payload(p, _r)
        closed = p.value.to_s == "closed"
        buttons(p, [ { "command" => "pulse", "label" => text(closed ? :unlock : :lock), "icon" => closed ? "lock-open" : "lock-closed" } ])
      end
    end

    class ValveOpenClose < Base
      describe key: "valve_open_close", label: "Válvula", icon: "beaker", kind: "buttons", capabilities: %w[onoff], match: ->(p) { TileFeatures.named?(p, /v[áa]lvula|valve|registro/i) }
      texts en: { label: "Valve", open: "Open", close: "Close" }, es: { label: "Válvula", open: "Abrir", close: "Cerrar" },
            "pt-BR" => { open: "Abrir", close: "Fechar" }
      def self.payload(p, _r) = buttons(p, [ { "command" => "on", "label" => text(:open), "icon" => "chevron-up", "active" => p.value == true },
                                             { "command" => "off", "label" => text(:close), "icon" => "chevron-down", "active" => p.value == false } ])
    end

    class SelectOptions < Chips
      describe key: "select_options", label: "Opções", icon: "view-list", kind: "chips", capabilities: %w[enum], match: ->(p) { p.helper != "alarm_panel" }
      texts en: { label: "Options" }, es: { label: "Opciones" }
    end

    class NumericInput < Stepper
      describe key: "numeric_input", label: "Número", icon: "calculator", kind: "stepper", capabilities: %w[setpoint dimmer]
      texts en: { label: "Number" }, es: { label: "Número" }
    end

    class MediaVolume < Base
      describe key: "media_volume", label: "Volume", icon: "volume-up", kind: "slider", capabilities: %w[media speaker],
               match: ->(p) { Points::Command.commands_for(p).include?("volume") }
      texts en: { label: "Volume" }, es: { label: "Volumen" }
      def self.payload(p, _r) = { "min" => 0, "max" => 100, "step" => 1, "value" => (p.value["volume"] if p.value.is_a?(Hash)), "command" => "volume", "unit" => "%" }
    end

    class MediaPlayback < Base
      describe key: "media_playback", label: "Reprodução", icon: "play", kind: "buttons", capabilities: %w[media]
      texts en: { label: "Playback", prev: "Previous", play: "Play/pause", next: "Next" }, es: { label: "Reproducción", prev: "Anterior", play: "Reproducir/pausar", next: "Siguiente" },
            "pt-BR" => { prev: "Anterior", play: "Tocar/pausar", next: "Próxima" }

      def self.payload(p, _r)
        playing = p.value.is_a?(Hash) && p.value["state"] == "playing"
        buttons(p, [ { "command" => "previous", "label" => text(:prev), "icon" => "rewind" },
                     { "command" => playing ? "pause" : "resume", "label" => text(:play), "icon" => playing ? "pause" : "play", "active" => playing },
                     { "command" => "next", "label" => text(:next), "icon" => "fast-forward" } ])
      end
    end

    # Botões de ação do helper (contador: +1, −1, zerar; temporizador...).
    class CounterActions < Base
      describe key: "counter_actions", label: "Ações", icon: "plus-circle", kind: "buttons", capabilities: Point::CAPABILITIES.keys,
               match: ->(p) { Points::Command.actions_for(p).any? }
      texts en: { label: "Actions" }, es: { label: "Acciones" }

      def self.payload(p, _r)
        labels = p.helper_type.respond_to?(:command_labels) ? p.helper_type.command_labels : {}
        buttons(p, Points::Command.actions_for(p).map { |c| { "command" => c, "label" => (labels[c] || PointsHelper::ACTION_BUTTONS.dig(c, 1) || c).to_s, "icon" => PointsHelper::ACTION_BUTTONS.dig(c, 0) || "lightning-bolt" } })
      end
    end

    class PressButton < Base
      CMD = { "command" => "press", "gate" => "pulse", "script" => "run" }.freeze
      describe key: "press", label: "Botão", icon: "cursor-click", kind: "buttons", capabilities: CMD.keys
      texts en: { label: "Button", go: "Press" }, es: { label: "Botón", go: "Pulsar" }, "pt-BR" => { go: "Acionar" }
      def self.payload(p, _r) = buttons(p, [ { "command" => CMD[p.capability], "label" => text(:go), "icon" => "cursor-click" } ])
    end

    # Linha das últimas 24 h (média por hora dos rollups).
    class TrendGraph < Base
      describe key: "trend", label: "Gráfico de tendência", icon: "trending-up", kind: "trend", capabilities: %w[measure setpoint dimmer counter]
      texts en: { label: "Trend graph" }, es: { label: "Gráfico de tendencia" }

      def self.payload(p, _r)
        values = ReadingRollup.where(point_id: p.id, bucket: "1h", starts_at: 24.hours.ago..).order(:starts_at).pluck(:avg).compact.map { |v| v.to_f.round(2) }
        values << p.value.to_f if p.value.is_a?(Numeric)
        { "values" => values.last(25), "min" => values.min, "max" => values.max, "value" => p.value, "unit" => p.unit }
      end
    end

    class BarGauge < Base
      describe key: "bar_gauge", label: "Barra", icon: "chart-bar", kind: "bar", capabilities: %w[measure counter setpoint dimmer]
      texts en: { label: "Bar gauge" }, es: { label: "Barra" }

      def self.payload(p, _r)
        min, max = (p.min || 0).to_f, (p.max || 100).to_f
        ratio = p.value.is_a?(Numeric) && max > min ? ((p.value - min) / (max - min)).clamp(0, 1).round(3) : nil
        { "value" => p.value, "min" => min, "max" => max, "ratio" => ratio, "unit" => p.unit }
      end
    end
  end
end
