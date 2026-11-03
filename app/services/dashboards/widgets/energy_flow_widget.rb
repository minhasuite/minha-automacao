module Dashboards
  module Widgets
    # Fluxo de energia (o cartão de distribuição do HA): rede, solar e bateria
    # para a casa, com as linhas animadas na direção e na velocidade da
    # potência de agora. Cada papel é um ponto de potência (W ou kW) qualquer:
    # rede positiva = comprando (`grid_invert` se o medidor diz o contrário),
    # bateria positiva = descarregando (`battery_invert`). Sem `home`, a casa
    # é o que sobra (rede + solar + bateria).
    class EnergyFlowWidget < Base
      ROLES = %w[grid solar battery battery_soc home].freeze
      FLAGS = %w[grid_invert battery_invert].freeze
      # ondaB2 (B12): parcela fóssil da rede (%, ex. Electricity Maps) e previsão solar de hoje (kWh).
      EXTRAS = %w[co2 solar_forecast].freeze
      # Abaixo disso (W) a linha fica parada.
      IDLE_W = 5

      describe type: "energy_flow", label: "Fluxo de energia", icon: "switch-horizontal", params: ROLES + FLAGS + EXTRAS
      texts en: { "label" => "Energy flow", "need_grid" => "set at least the grid or the solar" },
            es: { "label" => "Flujo de energía", "need_grid" => "indica al menos la red o la solar" },
            "pt-BR" => { "need_grid" => "informe ao menos a rede ou o solar" }

      def self.errors(w)
        e = (ROLES + EXTRAS).filter_map { |k| "#{k} precisa ser texto (id ou chave do ponto)" if w.key?(k) && !w[k].is_a?(String) }
        e += FLAGS.filter_map { |k| "#{k} precisa ser true ou false" if w.key?(k) && ![ true, false ].include?(w[k]) }
        e << text(:need_grid) unless w["grid"].is_a?(String) || w["solar"].is_a?(String)
        e
      end

      def self.data(r, w, _binds)
        pts = ROLES.to_h { |k| [ k, r.use(r.point(w[k])) ] }
        watts = ROLES.to_h { |k| [ k, watts(pts[k]) ] }
        watts["grid"] = -watts["grid"] if watts["grid"] && w["grid_invert"]
        watts["battery"] = -watts["battery"] if watts["battery"] && w["battery_invert"]
        flows = split(grid: watts["grid"], solar: watts["solar"], battery: watts["battery"], home: watts["home"])
        soc = pts["battery_soc"]&.value
        data = { "has" => ROLES.index_with { |k| pts[k].present? }, "watts" => watts.except("battery_soc"), "flows" => flows,
                 "soc" => (soc.to_f.round if soc.is_a?(Numeric)), "missing" => pts["grid"].nil? && pts["solar"].nil?,
                 "point_ids" => pts.values.compact.map(&:id) }
        extra = EXTRAS.to_h { |k| [ k, r.use(r.point(w[k])) ] }
        co2 = extra["co2"]&.value
        data["fossil_pct"] = co2.to_f.clamp(0, 100).round if co2.is_a?(Numeric)
        fc = extra["solar_forecast"]&.value
        data["forecast_kwh"] = fc.to_f.round(1) if fc.is_a?(Numeric)
        [ data, pts.values.compact + extra.values.compact ]
      end

      # Potência em W (nil = sem leitura boa).
      def self.watts(p)
        return unless p&.quality == "good" && p.value.is_a?(Numeric)

        p.value.to_f * (p.unit.to_s.downcase.start_with?("k") ? 1000 : 1)
      end

      # Divide a potência entre os caminhos (W, sempre >= 0), na ordem do HA:
      # o solar serve a casa, depois carrega a bateria, depois vende; a
      # bateria serve a casa; a rede cobre o resto (e o que a bateria carrega
      # além do solar).
      def self.split(grid: nil, solar: nil, battery: nil, home: nil)
        g = grid.to_f
        s = [ solar.to_f, 0 ].max
        b = battery.to_f
        h = home ? [ home.to_f, 0 ].max : [ g + s + b, 0 ].max
        charge = [ -b, 0 ].max
        solar_home = [ s, h ].min
        solar_battery = [ s - solar_home, charge ].min
        solar_grid = [ s - solar_home - solar_battery, [ -g, 0 ].max ].min
        battery_home = [ [ b, 0 ].max, h - solar_home ].min
        grid_battery = [ charge - solar_battery, 0 ].max
        grid_home = [ [ g, 0 ].max - grid_battery, [ h - solar_home - battery_home, 0 ].max ].min
        { "solar_home" => solar_home, "solar_battery" => solar_battery, "solar_grid" => solar_grid, "battery_home" => battery_home,
          "grid_home" => [ grid_home, 0 ].max, "grid_battery" => grid_battery, "home" => h }.transform_values { |v| v.round(1) }
      end

      def self.attrs(p, _site = nil)
        (ROLES + EXTRAS).to_h { |k| [ k, p[k].presence ] }.merge(FLAGS.to_h { |k| [ k, p[k] == "1" || nil ] }).compact
      end

      def self.form = "web/dashboards/widget_forms/energy_flow"
    end
  end
end
