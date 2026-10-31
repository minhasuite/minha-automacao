module HelperTypes
  # Tendência (trend do HA): liga quando a origem está subindo (ou descendo,
  # com "inverter"). O gradiente é a inclinação da reta (mínimos quadrados)
  # das amostras na janela, em unidades por segundo, como no HA; liga quando
  # passa do gradiente mínimo. Com menos que o mínimo de amostras, fica
  # indisponível. Atributos: `gradient` e `samples`.
  class Trend < Plugin
    describe key: "trend", title: "Tendência", icon: "trending-down", capability: "onoff",
             description: "Liga quando um valor está subindo (ou descendo): temperatura subindo, nível do tanque caindo."
    fields %i[source window max_samples min_samples min_gradient invert]

    def self.assign(point, form)
      numeric_source!(point, form) or return
      a = point.address
      window = form.key?("window") ? Automations::Dsl.seconds(form["window"].to_s.strip.presence || 0) : a["window_s"].to_i
      max = (number(form["max_samples"]) || a["max_samples"] || 2).to_i
      min = (number(form["min_samples"]) || a["min_samples"] || 2).to_i
      grad = (form.key?("min_gradient") ? number(form["min_gradient"]) : a["min_gradient"]) || 0.0
      invert = form.key?("invert") ? ActiveModel::Type::Boolean.new.cast(form["invert"]) == true : a["invert"] == true
      point.data_type = "bool"
      point.writable = false
      point.address = a.merge("window_s" => window.to_i, "max_samples" => max, "min_samples" => min, "min_gradient" => grad, "invert" => invert)
      return point.errors.add(:base, "Janela inválida (vazio = sem limite de tempo; ex.: 30m, até 1 dia).") unless window&.between?(0, 86_400)

      point.errors.add(:base, "Amostras: mínimo de 2 e até #{Derivative::MAX_SAMPLES}, com o mínimo até o máximo.") unless min >= 2 && min <= max && max <= Derivative::MAX_SAMPLES
    end

    def self.sourced? = true

    def self.refresh!(point, now = Time.current)
      a = point.address
      samples = Derivative.samples!(point, now, window: a["window_s"].to_i, max: a["max_samples"].to_i)
      return point.report!(point.value, quality: "unavailable") if samples.size < a["min_samples"].to_i

      g = slope(samples)
      point.report_attrs!(point.attrs.to_h.merge("gradient" => g.round(6), "samples" => samples.size))
      point.report!(a["invert"] ? g < -a["min_gradient"].to_f : g > a["min_gradient"].to_f)
    end

    # Inclinação da reta pelos pontos [[t, v]] (por segundo).
    def self.slope(samples)
      t0 = samples.first[0]
      xs = samples.map { |t, _| t - t0 }
      ys = samples.map(&:last)
      mx = xs.sum / xs.size
      my = ys.sum / ys.size
      den = xs.sum { |x| (x - mx)**2 }
      den.zero? ? 0.0 : xs.zip(ys).sum { |x, y| (x - mx) * (y - my) } / den
    end

    def self.summary(point)
      a = point.address
      [ a["invert"] ? "liga descendo" : "liga subindo", "#{a['min_samples']} a #{a['max_samples']} amostras",
        (a["window_s"].to_i.positive? ? "janela de #{Automations::Dsl.duration_label(a['window_s'])}" : nil) ].compact.join(" · ")
    end
  end
end
