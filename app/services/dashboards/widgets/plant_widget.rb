module Dashboards
  module Widgets
    # Planta (ondaB2 B10; o `plant-status` do HA): umidade do solo,
    # temperatura, luz, fertilidade (condutividade) e bateria do sensor, cada
    # uma com a faixa boa e o aviso de baixo/alto. Os sensores vêm em `binds`
    # e a medida sai da classe ou da unidade; `limits` troca as faixas
    # ({"moisture": {"min": 20, "max": 60}}). Medida nova = linha em METRICS.
    class PlantWidget < Base
      METRICS = {
        "moisture" => { icon: "beaker", min: 15, max: 60, match: ->(p) { p.device_class == "moisture" || (p.unit.to_s == "%" && p.name.match?(/solo|soil|moist/i)) } },
        "temperature" => { icon: "thermometer", min: 10, max: 35, match: ->(p) { p.device_class == "temperature" || p.unit.to_s.match?(/°\s?[CF]\z/) } },
        "illuminance" => { icon: "sun", min: 2000, max: 50_000, match: ->(p) { p.device_class == "illuminance" || p.unit.to_s.casecmp?("lx") } },
        "conductivity" => { icon: "lightning-bolt", min: 350, max: 2000, match: ->(p) { p.device_class == "conductivity" || p.unit.to_s.match?(/S\/cm\z/) } },
        "battery" => { icon: "battery", min: 15, max: nil, match: ->(p) { p.device_class == "battery" } }
      }.freeze
      describe type: "plant", label: "Planta", icon: "leaf", required: %w[binds], params: %w[image], binds: true
      texts en: { label: "Plant", ok: "All good", low: "Low", high: "High", problem: "Needs attention: %{what}",
                  m: { moisture: "Moisture", temperature: "Temperature", illuminance: "Light", conductivity: "Fertility", battery: "Battery" } },
            es: { label: "Planta", ok: "Todo bien", low: "Bajo", high: "Alto", problem: "Necesita atención: %{what}",
                  m: { moisture: "Humedad", temperature: "Temperatura", illuminance: "Luz", conductivity: "Fertilidad", battery: "Batería" } },
            "pt-BR" => { ok: "Tudo certo", low: "Baixo", high: "Alto", problem: "Precisa de atenção: %{what}",
                         m: { moisture: "Umidade", temperature: "Temperatura", illuminance: "Luz", conductivity: "Fertilidade", battery: "Bateria" } }

      def self.form = "web/dashboards/widget_forms/cards"

      def self.data(_r, w, binds)
        limits = w["limits"].is_a?(Hash) ? w["limits"] : {}
        metrics = METRICS.filter_map do |key, m|
          p = binds.find { |b| m[:match].call(b) } or next
          lo = limits.dig(key, "min") || m[:min]
          hi = limits.dig(key, "max") || m[:max]
          v = p.value
          status = if !v.is_a?(Numeric) then "unknown"
          elsif lo && v < lo then "low"
          elsif hi && v > hi then "high"
          else "ok"
          end
          top = hi || (lo.to_f * 4).nonzero? || 100
          { "key" => key, "label" => text("m.#{key}"), "icon" => m[:icon], "point_id" => p.id, "value" => v, "unit" => p.unit, "min" => lo, "max" => hi,
            "status" => status, "status_text" => (text(status) if %w[low high].include?(status)), "ratio" => v.is_a?(Numeric) ? (v.to_f / top).clamp(0, 1).round(3) : 0 }.compact
        end
        bad = metrics.reject { |m| %w[ok unknown].include?(m["status"]) }
        [ { "point_ids" => binds.map(&:id), "metrics" => metrics, "problem" => bad.any?,
            "summary" => bad.any? ? text(:problem, what: bad.map { |m| m["label"].downcase }.to_sentence) : text(:ok),
            "image" => (w["image"] if w["image"].to_s.match?(Themes::IMAGE)) }.compact, [] ]
      end
    end
  end
end
