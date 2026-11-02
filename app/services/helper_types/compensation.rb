module HelperTypes
  # Compensação (compensation do HA, ondaA1 A10): corrige um sensor por
  # pares medidos "lido: certo" (um por linha), com a curva dos mínimos
  # quadrados de grau 1 (reta) a 3. Ex.: o sensor marca 20 quando o padrão
  # marca 21,3. Atributo `coefficients` (do termo de maior grau ao constante).
  class Compensation < Plugin
    PAIR = /\A\s*(-?[\d.,]+)\s*[:;=]\s*(-?[\d.,]+)\s*\z/

    describe key: "compensation", title: "Compensação", icon: "trending-up", capability: "measure",
             description: "Corrige um sensor por pares medidos (lido: certo), com uma reta ou curva de até grau 3."
    fields %i[source pairs degree decimals]
    texts "pt-BR" => { "form.source" => "Sensor de origem", "form.pairs" => "Pares lido: certo (um por linha)", "form.degree" => "Grau da curva (1 a 3)",
                       "form.decimals" => "Casas decimais", "hint.pairs" => "Ex.: 20: 21.3 — pelo menos grau + 1 pares.",
                       pair: "Linha %{n}: use lido: certo (ex.: 20: 21.3).", few: "Para grau %{d}, informe pelo menos %{n} pares diferentes.", summary: "grau %{d}, %{n} pares" },
          en: { title: "Compensation", description: "Corrects a sensor from measured pairs (read: true), with a line or curve up to degree 3.",
                "form.source" => "Source sensor", "form.pairs" => "Pairs read: true (one per line)", "form.degree" => "Curve degree (1 to 3)",
                "form.decimals" => "Decimal places", "hint.pairs" => "E.g.: 20: 21.3 — at least degree + 1 pairs.",
                pair: "Line %{n}: use read: true (e.g. 20: 21.3).", few: "For degree %{d}, enter at least %{n} different pairs.", summary: "degree %{d}, %{n} pairs" },
          es: { title: "Compensación", description: "Corrige un sensor por pares medidos (leído: correcto), con una recta o curva de hasta grado 3.",
                "form.source" => "Sensor de origen", "form.pairs" => "Pares leído: correcto (uno por línea)", "form.degree" => "Grado de la curva (1 a 3)",
                "form.decimals" => "Decimales", "hint.pairs" => "Ej.: 20: 21.3 — al menos grado + 1 pares.",
                pair: "Línea %{n}: usa leído: correcto (ej.: 20: 21.3).", few: "Para grado %{d}, indica al menos %{n} pares distintos.", summary: "grado %{d}, %{n} pares" }

    def self.form_spec
      [ [ :source, :source, { index: 0 } ], [ :pairs, :textarea, { value: ->(p) { Array(p.address["pairs"]).map { |x, y| "#{x}: #{y}" }.join("\n") } } ],
        [ :degree, :number, { value: ->(p) { p.address["degree"] || 1 } } ], [ :decimals, :number, { value: ->(p) { p.address["decimals"] || 2 } } ] ]
    end

    def self.assign(point, form)
      src = numeric_source!(point, form) or return
      a = point.address
      pairs = a["pairs"]
      if form.key?("pairs")
        pairs = form["pairs"].to_s.lines.map(&:strip).compact_blank.each_with_index.map do |l, i|
          m = PAIR.match(l) or return point.errors.add(:base, text(:pair, n: i + 1))
          [ m[1].tr(",", ".").to_f, m[2].tr(",", ".").to_f ]
        end
      end
      degree = (form.key?("degree") ? number(form["degree"]) : a["degree"] || 1).to_i.clamp(1, 3)
      decimals = (form.key?("decimals") ? number(form["decimals"]) : a["decimals"] || 2).to_i
      point.data_type = "decimal"
      point.writable = false
      point.unit ||= src.unit
      pairs = Array(pairs)
      point.address = a.merge("pairs" => pairs, "degree" => degree, "decimals" => decimals, "coefficients" => nil)
      return point.errors.add(:base, text(:few, d: degree, n: degree + 1)) if pairs.map(&:first).uniq.size <= degree
      return point.errors.add(:base, text(:decimals)) unless decimals.between?(0, 6)

      point.address = point.address.merge("coefficients" => fit(pairs, degree))
    end

    def self.sourced? = true

    def self.refresh!(point)
      v = reading(source(point))
      return point.report!(point.value, quality: "unavailable") if v.nil?

      c = point.address["coefficients"]
      point.report_attrs!(point.attrs.to_h.merge("coefficients" => c))
      point.report!(c.reverse.each_with_index.sum { |k, i| k * (v**i) }.round(point.address["decimals"].to_i))
    end

    # Mínimos quadrados: resolve (XᵀX)·c = Xᵀy por eliminação de Gauss.
    # Devolve do termo de maior grau ao constante (como o numpy.polyfit do HA).
    def self.fit(pairs, degree)
      n = degree + 1
      m = Array.new(n) { |i| Array.new(n) { |j| pairs.sum { |x, _| x**(i + j) } } }
      r = Array.new(n) { |i| pairs.sum { |x, y| y * (x**i) } }
      n.times do |col|
        piv = (col...n).max_by { |row| m[row][col].abs }
        m[col], m[piv] = m[piv], m[col]
        r[col], r[piv] = r[piv], r[col]
        (col + 1...n).each do |row|
          f = m[row][col] / m[col][col]
          (col...n).each { |k| m[row][k] -= f * m[col][k] }
          r[row] -= f * r[col]
        end
      end
      c = Array.new(n, 0.0)
      (n - 1).downto(0) { |i| c[i] = (r[i] - ((i + 1)...n).sum { |k| m[i][k] * c[k] }) / m[i][i] }
      c.reverse.map { |x| x.round(8) }
    end

    def self.summary(point) = text(:summary, d: point.address["degree"], n: Array(point.address["pairs"]).size)
  end
end
