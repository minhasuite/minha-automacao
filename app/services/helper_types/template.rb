module HelperTypes
  # Sensor calculado (template do HA): uma expressão sobre outros pontos,
  # refeita quando um ponto de origem muda. Número e sim/não usam a mesma
  # calculadora das automações (dentaku: `sala.temperatura - externo.temperatura`);
  # texto usa o Liquid delas (`{{ points["sala.luz"].text }}`). Origens = pontos
  # cuja chave aparece na expressão. Erro na conta = ponto "Com erro".
  #
  # Lote 5 (G9): `previous` é o próprio valor antes da conta (acumulador,
  # "previous + sala.kwh * tarifa"); "a cada" refaz pelo relógio em vez da
  # mudança das origens (o template por gatilho do HA); resultado "data e
  # hora" (timestamp: número de segundos ou texto vira "AAAA-MM-DDTHH:MM"); e
  # atributos (uma linha por atributo, "nome: texto Liquid") guardados em
  # `points.attrs`, para o widget e o Liquid (`points["k"].attrs.nome`).
  class Template < Plugin
    KINDS = { "number" => [ "Número", "measure" ], "bool" => [ "Liga/desliga (sim/não)", "onoff" ], "text" => [ "Texto", "text" ],
              "timestamp" => [ "Data e hora", "datetime" ] }.freeze
    # Valor do `previous` quando o ponto ainda não tem valor.
    START = { "number" => 0, "bool" => false, "text" => "", "timestamp" => "" }.freeze
    MAX = 500
    MAX_ATTRS = 10
    # Consulta ao conjunto de pontos (Lote 4, G8): a origem é o local inteiro.
    DYNAMIC = /\b(?:#{Automations::Expr::AGGREGATES.keys.join('|')})\s*\(|points_where/

    describe key: "template", title: "Sensor calculado", icon: "sparkles", capability: "measure",
             description: "Um valor calculado a partir de outros pontos: diferença de temperatura, consumo somado."
    fields %i[kind expr unit every attrs]

    def self.assign(point, form)
      kind = form["kind"].presence_in(KINDS.keys) || point.address["kind"] || "number"
      expr = form.key?("expr") ? form["expr"].to_s.strip : point.address["expr"].to_s
      point.capability = KINDS[kind][1]
      point.data_type = Point::CAPABILITIES[point.capability]
      point.writable = false
      point.unit = form["unit"] if kind == "number" && form.key?("unit")
      attrs = form.key?("attrs") ? parse_attrs(form["attrs"].to_s) : point.address["attrs"].to_h
      every = form.key?("every") ? (Automations::Dsl.seconds(form["every"].to_s.strip.presence || 0) || -1) : point.address["every"]
      text = ([ expr ] + attrs.to_h.values).join("\n")
      sources = point.site.points.where.not(id: point.id).pluck(:id, :key).select { |_, k| text.include?(k) }.map(&:first)
      sources << "*" if text.match?(DYNAMIC)
      sources = [] if every.to_i.positive? # "a cada": só o relógio refaz
      point.address = point.address.merge("kind" => kind, "expr" => expr, "sources" => sources, "attrs" => attrs.presence,
                                           "every" => (every if every.to_i.positive?)).compact
      return point.errors.add(:base, "Escreva a expressão (até #{MAX} caracteres).") unless expr.present? && expr.size <= MAX
      return point.errors.add(:base, "\"A cada\" precisa ser de 1 min a 24 h, em minutos inteiros (ex.: 5m).") unless every_ok?(every)
      return point.errors.add(:base, "Atributos: até #{MAX_ATTRS}, um por linha, \"nome: texto\" (nome com letras minúsculas, números e _).") if attrs.nil? || attrs.size > MAX_ATTRS

      error = %w[text timestamp].include?(kind) && !expr_like?(expr) ? template_error(expr) : expr_error(expr)
      error ||= attrs.values.lazy.filter_map { |t| template_error(t) }.first
      point.errors.add(:base, "Expressão inválida: #{error}") if error
    end

    def self.every_ok?(every) = every.nil? || every.zero? || (every.between?(60, 86_400) && (every % 60).zero?)

    # "nome: texto" por linha → {nome => texto} (nil se alguma linha não serve).
    def self.parse_attrs(raw)
      raw.lines.map(&:strip).compact_blank.to_h do |line|
        name, text = line.split(":", 2).map(&:strip)
        return nil unless name.to_s.match?(Automations::Dsl::VAR) && text.present? && text.size <= MAX

        [ name, text ]
      end
    end

    # Data e hora pode vir de conta (segundos) ou de texto: conta = sem {{ }}.
    def self.expr_like?(expr) = !expr.include?("{{") && !expr.include?("{%")

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
      kind = point.address["kind"]
      ctx = Automations::Context.new(site: point.site, vars: { "previous" => point.value.nil? ? START[kind] : point.value })
      expr = point.address["expr"]
      v = case kind
      when "text" then ctx.render(expr)
      when "bool" then [ true, 1 ].include?(ctx.calc(expr))
      when "timestamp" then timestamp(expr_like?(expr) ? ctx.calc(expr) : ctx.render(expr), ctx.now.time_zone)
      else ctx.calc(expr).then { |n| n.is_a?(Numeric) ? n : Float(n.to_s, exception: false) }
      end
      attrs = point.address["attrs"].to_h.transform_values { |t| ctx.render(t, limit: 500) }
      point.update_column(:attrs, attrs) if attrs != point.attrs
      point.report!(v)
    rescue Automations::Context::Error => e
      Rails.logger.info("[helpers] #{point.key}: #{e.message}")
      point.report!(point.value, quality: "error")
    end

    # Segundos desde 1970 ou texto de data → "AAAA-MM-DDTHH:MM" no fuso do local.
    def self.timestamp(v, zone)
      t = v.is_a?(Numeric) ? Time.zone.at(v) : zone.parse(v.to_s)
      t&.in_time_zone(zone)&.strftime("%Y-%m-%dT%H:%M")
    rescue ArgumentError
      nil
    end

    def self.summary(point)
      every = " · a cada #{Automations::Dsl.duration_label(point.address['every'])}" if point.address["every"]
      "#{KINDS.dig(point.address['kind'], 0)} · #{point.address['expr'].to_s.truncate(50)}#{every}"
    end
  end
end
