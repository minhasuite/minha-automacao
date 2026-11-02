module Drivers
  # Base do ar-condicionado (integ2: Daikin, Midea, LG ThinQ). O fabricante
  # só lê o estado (`read` → {power, target, mode, fan, current}, já com as
  # opções do MA) e grava um campo (`write(device, field, value)`); pontos,
  # leitura, resumo `climate` e comando são daqui, pelo
  # `config/device_maps/climate.yml`. Ponto: `address` {field}.
  class Climate
    MAP = YAML.load_file(Rails.root.join("config/device_maps/climate.yml")).freeze
    FIELDS = %w[power target mode fan current].freeze

    class << self
      def vendor = raise(NotImplementedError)
      def read(_device) = raise(NotImplementedError)
      def write(_device, _field, _value) = raise(NotImplementedError)
      # Nuvem demora a refletir: grava o pedido e não relê (LG).
      def reread? = true

      def codes(kind) = MAP.dig("vendors", vendor, kind)
      def label(kind, raw) = codes(kind)[raw.to_s]
      def code(kind, label) = codes(kind).key(label) || raise(Integrations::Error, "#{label} não existe neste aparelho.")

      def points
        MAP["points"].map do |p|
          extra = %w[mode fan].include?(p["field"]) ? { "options" => codes(p["field"]).values.uniq } : {}
          p.except("field").merge(extra).merge("address" => { "field" => p["field"] })
        end
      end

      # Entrada de inventário de um AC (formato de `Integrations`).
      def climate_entry(id:, name:, manufacturer:, address:, model: nil, poll_s: 60)
        { "id" => id, "kind" => vendor, "name" => name, "manufacturer" => manufacturer, "model" => model, "category" => "Ar-condicionado",
          "online" => true, "poll_s" => poll_s, "address" => address, "points" => points }
      end

      def poll(device)
        state = read(device).slice(*FIELDS)
        device.update_columns(status: "online", last_seen_at: Time.current)
        report(device, state)
      end

      def report(device, state)
        device.points.reject(&:disabled).each do |p|
          f = p.address["field"]
          v = f == "climate" ? state.compact : state[f]
          p.report!(v) unless v.nil?
        end
      end

      def unavailable!(device) = Drivers.offline!(device)
    end

    def execute(point, command, value)
      v = Points::Command.new(point, command, value).new_value
      device = point.device
      self.class.write(device, point.address["field"], v)
      return self.class.poll(device) if self.class.reread?

      point.report!(v)
      summary = device.points.find { |p| p.address["field"] == "climate" }
      summary&.report!(summary.value.to_h.merge(point.address["field"] => v))
    end
  end
end
