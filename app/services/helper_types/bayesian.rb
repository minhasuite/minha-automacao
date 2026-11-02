module HelperTypes
  # Bayesiano (bayesian do HA, ondaA1 A10): junta várias pistas numa
  # probabilidade ("alguém em casa": movimento, porta, celular, TV). Cada
  # linha é `ponto = valor ; P(pista | verdade) ; P(pista | falso)`, com
  # ponto pela chave; o valor pode ser on/off, número ou texto. Liga quando
  # a probabilidade passa do limite. Atributos: `probability` e `observed`.
  class Bayesian < Plugin
    LINE = /\A\s*([a-z0-9_.]+)\s*=\s*([^;]+?)\s*;\s*([\d.,]+)\s*;\s*([\d.,]+)\s*\z/
    MAX = 20

    describe key: "bayesian", title: "Bayesiano", icon: "sparkles", capability: "onoff",
             description: "Junta várias pistas numa probabilidade e liga quando passa do limite: alguém em casa, alguém dormindo, banho em andamento."
    fields %i[prior threshold observations]
    texts "pt-BR" => { "form.prior" => "Probabilidade inicial (0 a 1)", "form.threshold" => "Liga acima de (0 a 1)", "form.observations" => "Pistas (uma por linha)",
                       "hint.observations" => "ponto = valor ; P(pista se for verdade) ; P(pista se for falso). Ex.: sala.movimento = on ; 0.9 ; 0.2",
                       line: "Linha %{n}: use ponto = valor ; 0.9 ; 0.1 (com o ponto pela chave).", point: "Linha %{n}: o ponto %{key} não existe.",
                       probs: "Probabilidades entre 0 e 1 (a inicial e o limite também, sem 0 e 1 exatos na inicial).", empty: "Informe de 1 a %{max} pistas.",
                       summary: "%{n} pistas, liga acima de %{t}" },
          en: { title: "Bayesian", description: "Combines several clues into a probability and turns on above a threshold: someone home, someone asleep, shower running.",
                "form.prior" => "Prior probability (0 to 1)", "form.threshold" => "On above (0 to 1)", "form.observations" => "Clues (one per line)",
                "hint.observations" => "point = value ; P(clue if true) ; P(clue if false). E.g.: room.motion = on ; 0.9 ; 0.2",
                line: "Line %{n}: use point = value ; 0.9 ; 0.1 (point by key).", point: "Line %{n}: point %{key} does not exist.",
                probs: "Probabilities between 0 and 1 (prior and threshold too, prior not exactly 0 or 1).", empty: "Enter 1 to %{max} clues.",
                summary: "%{n} clues, on above %{t}" },
          es: { title: "Bayesiano", description: "Junta varias pistas en una probabilidad y enciende cuando pasa del límite: alguien en casa, alguien durmiendo, ducha en curso.",
                "form.prior" => "Probabilidad inicial (0 a 1)", "form.threshold" => "Enciende arriba de (0 a 1)", "form.observations" => "Pistas (una por línea)",
                "hint.observations" => "punto = valor ; P(pista si es verdad) ; P(pista si es falso). Ej.: sala.movimiento = on ; 0.9 ; 0.2",
                line: "Línea %{n}: usa punto = valor ; 0.9 ; 0.1 (punto por la clave).", point: "Línea %{n}: el punto %{key} no existe.",
                probs: "Probabilidades entre 0 y 1 (la inicial y el límite también, sin 0 ni 1 exactos en la inicial).", empty: "Indica de 1 a %{max} pistas.",
                summary: "%{n} pistas, enciende arriba de %{t}" }

    def self.form_spec
      [ [ :prior, :number, { value: ->(p) { p.address["prior"] || 0.5 } } ], [ :threshold, :number, { value: ->(p) { p.address["threshold"] || 0.5 } } ],
        [ :observations, :textarea, { value: ->(p) { Array(p.address["observations"]).map { |o| "#{o['key']} = #{o['is']} ; #{o['p_true']} ; #{o['p_false']}" }.join("\n") } } ] ]
    end

    def self.assign(point, form)
      a = point.address
      prior = (form.key?("prior") ? number(form["prior"]) : a["prior"]) || 0.5
      threshold = (form.key?("threshold") ? number(form["threshold"]) : a["threshold"]) || 0.5
      point.data_type = "bool"
      point.writable = false
      obs = a["observations"]
      if form.key?("observations")
        lines = form["observations"].to_s.lines.map(&:strip).compact_blank
        obs = lines.each_with_index.map do |l, i|
          m = LINE.match(l) or return point.errors.add(:base, text(:line, n: i + 1))
          p = point.site.points.find_by(key: m[1]) or return point.errors.add(:base, text(:point, n: i + 1, key: m[1]))
          { "point_id" => p.id, "key" => p.key, "is" => m[2], "p_true" => m[3].tr(",", ".").to_f, "p_false" => m[4].tr(",", ".").to_f }
        end
      end
      obs = Array(obs)
      point.address = a.merge("prior" => prior, "threshold" => threshold, "observations" => obs, "sources" => obs.pluck("point_id").uniq)
      return point.errors.add(:base, text(:empty, max: MAX)) unless obs.size.between?(1, MAX)

      probs = obs.flat_map { |o| [ o["p_true"], o["p_false"] ] } + [ threshold ]
      point.errors.add(:base, text(:probs)) unless probs.all? { |x| x.between?(0, 1) } && prior.positive? && prior < 1
    end

    def self.sourced? = true

    def self.refresh!(point)
      a = point.address
      seen = []
      prob = a["observations"].reduce(a["prior"].to_f) do |p, o|
        src = point.site.points.find_by(id: o["point_id"])
        next p unless src&.quality == "good" && !src.value.nil?

        hit = matches?(src.value, o["is"])
        seen << o["key"] if hit
        update(p, hit ? o["p_true"].to_f : 1 - o["p_true"].to_f, hit ? o["p_false"].to_f : 1 - o["p_false"].to_f)
      end
      point.report_attrs!(point.attrs.to_h.merge("probability" => prob.round(4), "observed" => seen))
      point.report!(prob > a["threshold"].to_f)
    end

    # Bayes: P(V|pista) = P(pista|V)·P(V) / (P(pista|V)·P(V) + P(pista|F)·(1 − P(V))).
    def self.update(prior, p_true, p_false)
      den = (p_true * prior) + (p_false * (1 - prior))
      den.zero? ? prior : (p_true * prior) / den
    end

    def self.matches?(value, want)
      w = want.to_s.strip
      return value == (w == "on") if [ true, false ].include?(value) && %w[on off].include?(w)
      return value.to_f == w.tr(",", ".").to_f if value.is_a?(Numeric) && w.match?(/\A-?[\d.,]+\z/)

      value.to_s == w
    end

    def self.summary(point) = text(:summary, n: Array(point.address["observations"]).size, t: point.address["threshold"])
  end
end
