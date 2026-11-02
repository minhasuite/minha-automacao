module HelperTypes
  # Risco de mofo (mold_indicator do HA, ondaA1 A10): com a temperatura e a
  # umidade de dentro e a temperatura de fora, estima a umidade no ponto mais
  # frio da parede (fator de calibração) pelo ponto de orvalho (Magnus). O
  # valor é essa umidade em %; acima de ~70% há risco de mofo. Atributos:
  # `dewpoint` e `critical_temp`.
  class MoldIndicator < Plugin
    A = 17.62
    B = 243.12

    describe key: "mold_indicator", title: "Risco de mofo", icon: "cloud-rain", capability: "measure",
             description: "Umidade estimada no canto mais frio da parede, pela temperatura e umidade de dentro e a temperatura de fora."
    fields %i[source humidity outdoor calibration]
    texts "pt-BR" => { "form.source" => "Temperatura de dentro", "form.humidity" => "Umidade de dentro", "form.outdoor" => "Temperatura de fora",
                       "form.calibration" => "Fator de calibração", "hint.calibration" => "0 a 1: o quanto a parede fica perto da temperatura de fora (o HA usa ~2,0 como razão; aqui 0,5 é um bom começo).",
                       pick: "Escolha os três sensores (números).", calibration: "Fator entre 0 e 1.", summary: "calibração %{f}" },
          en: { title: "Mold indicator", description: "Estimated humidity at the coldest spot of the wall, from the indoor temperature and humidity and the outdoor temperature.",
                "form.source" => "Indoor temperature", "form.humidity" => "Indoor humidity", "form.outdoor" => "Outdoor temperature",
                "form.calibration" => "Calibration factor", "hint.calibration" => "0 to 1: how close the wall gets to the outdoor temperature (0.5 is a good start).",
                pick: "Choose the three sensors (numbers).", calibration: "Factor between 0 and 1.", summary: "calibration %{f}" },
          es: { title: "Riesgo de moho", description: "Humedad estimada en el rincón más frío de la pared, por la temperatura y humedad de adentro y la temperatura de afuera.",
                "form.source" => "Temperatura de adentro", "form.humidity" => "Humedad de adentro", "form.outdoor" => "Temperatura de afuera",
                "form.calibration" => "Factor de calibración", "hint.calibration" => "0 a 1: cuánto se acerca la pared a la temperatura de afuera (0,5 es un buen comienzo).",
                pick: "Elige los tres sensores (números).", calibration: "Factor entre 0 y 1.", summary: "calibración %{f}" }

    def self.form_spec
      [ [ :source, :source, { index: 0 } ], [ :humidity, :source, { index: 1 } ], [ :outdoor, :source, { index: 2 } ],
        [ :calibration, :number, { value: ->(p) { p.address["calibration"] || 0.5 } } ] ]
    end

    def self.assign(point, form)
      a = point.address
      ids = %w[source humidity outdoor].each_with_index.map { |k, i| form[k].presence || a.dig("sources", i) }
      pts = ids.map { |id| point.site.points.find_by(id: id) }
      return point.errors.add(:base, text(:pick)) unless pts.all? { |p| p&.numeric? && p.id != point.id }

      f = (form.key?("calibration") ? number(form["calibration"]) : a["calibration"]) || 0.5
      point.data_type = "decimal"
      point.writable = false
      point.unit = "%"
      point.device_class = "humidity"
      point.address = a.merge("sources" => ids, "calibration" => f)
      point.errors.add(:base, text(:calibration)) unless f.between?(0, 1)
    end

    def self.sourced? = true

    def self.refresh!(point)
      t_in, rh, t_out = point.address["sources"].map { |id| reading(point.site.points.find_by(id: id)) }
      return point.report!(point.value, quality: "unavailable") if [ t_in, rh, t_out ].any?(&:nil?)

      value, dew, crit = compute(t_in, rh, t_out, point.address["calibration"].to_f)
      point.report_attrs!(point.attrs.to_h.merge("dewpoint" => dew, "critical_temp" => crit))
      point.report!(value)
    end

    # → [umidade no canto frio %, ponto de orvalho °C, temperatura do canto °C].
    def self.compute(t_in, rh, t_out, f)
      gamma = Math.log([ rh, 0.1 ].max / 100.0) + ((A * t_in) / (B + t_in))
      dew = (B * gamma) / (A - gamma)
      crit = t_in - ((t_in - t_out) * f)
      sat = ->(t) { 6.112 * Math.exp((A * t) / (B + t)) }
      rh_crit = (rh * sat.(t_in) / sat.(crit)).clamp(0, 100)
      [ rh_crit.round(1), dew.round(1), crit.round(1) ]
    end

    def self.summary(point) = text(:summary, f: point.address["calibration"])
  end
end
