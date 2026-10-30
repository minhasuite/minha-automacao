module HelperTypes
  # Sensor calculado (template do HA): uma expressão sobre outros pontos,
  # refeita quando um ponto de origem muda. Número e sim/não usam a mesma
  # calculadora das automações (dentaku: `sala.temperatura - externo.temperatura`);
  # texto usa o Liquid delas (`{{ points["sala.luz"].text }}`). Origens = pontos
  # cuja chave aparece na expressão. Erro na conta = ponto "Com erro".
  class Template < Plugin
    KINDS = { "number" => [ "Número", "measure" ], "bool" => [ "Liga/desliga (sim/não)", "onoff" ], "text" => [ "Texto", "text" ] }.freeze
    MAX = 500
    # Consulta ao conjunto de pontos (Lote 4, G8): a origem é o local inteiro.
    DYNAMIC = /\b(?:#{Automations::Expr::AGGREGATES.keys.join('|')})\s*\(|points_where/

    describe key: "template", title: "Sensor calculado", icon: "sparkles", capability: "measure",
             description: "Um valor calculado a partir de outros pontos: diferença de temperatura, consumo somado."
    fields %i[kind expr unit]

    def self.assign(point, form)
      kind = form["kind"].presence_in(KINDS.keys) || point.address["kind"] || "number"
      expr = form.key?("expr") ? form["expr"].to_s.strip : point.address["expr"].to_s
      point.capability = KINDS[kind][1]
      point.data_type = Point::CAPABILITIES[point.capability]
      point.writable = false
      point.unit = form["unit"] if kind == "number" && form.key?("unit")
      sources = point.site.points.where.not(id: point.id).pluck(:id, :key).select { |_, k| expr.include?(k) }.map(&:first)
      sources << "*" if expr.match?(DYNAMIC)
      point.address = point.address.merge("kind" => kind, "expr" => expr, "sources" => sources)
      return point.errors.add(:base, "Escreva a expressão (até #{MAX} caracteres).") unless expr.present? && expr.size <= MAX

      error = kind == "text" ? template_error(expr) : expr_error(expr)
      point.errors.add(:base, "Expressão inválida: #{error}") if error
    end

    def self.expr_error(expr)
      Automations::Expr.calculator.ast(expr)
      nil
    rescue Dentaku::Error, Dentaku::ParseError, Dentaku::TokenizerError => e
      e.message.truncate(120)
    end

    def self.template_error(expr)
      Liquid::Template.parse(expr, error_mode: :strict)
      nil
    rescue Liquid::Error => e
      e.message.truncate(120)
    end

    def self.sourced? = true

    def self.refresh!(point)
      ctx = Automations::Context.new(site: point.site)
      expr = point.address["expr"]
      v = case point.address["kind"]
      when "text" then ctx.render(expr)
      when "bool" then [ true, 1 ].include?(ctx.calc(expr))
      else ctx.calc(expr).then { |n| n.is_a?(Numeric) ? n : Float(n.to_s, exception: false) }
      end
      point.report!(v)
    rescue Automations::Context::Error => e
      Rails.logger.info("[helpers] #{point.key}: #{e.message}")
      point.report!(point.value, quality: "error")
    end

    def self.summary(point) = "#{KINDS.dig(point.address['kind'], 0)} · #{point.address['expr'].to_s.truncate(50)}"
  end
end
