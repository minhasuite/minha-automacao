module Automations
  # Calculadora das expressões (dentaku): só aritmética, comparação, lógica e
  # funções do dentaku (if, round, min, max...), sem código arbitrário.
  # Lote 4 (G8): funções sobre o conjunto de pontos, com a consulta do
  # `Points::Query` em texto: `count_points("state=on tag=luz")`,
  # `sum_points(...)`, `min_points`, `max_points`, `avg_points`.
  module Expr
    AGGREGATES = {
      "count_points" => ->(values) { values.size },
      "sum_points" => ->(values) { values.grep(Numeric).sum },
      "min_points" => ->(values) { values.grep(Numeric).min },
      "max_points" => ->(values) { values.grep(Numeric).max },
      "avg_points" => ->(values) { (n = values.grep(Numeric)).any? ? n.sum.to_f / n.size : nil }
    }.freeze

    # `ctx` (Automations::Context) responde à consulta; sem ele (só validar a
    # expressão) as funções existem mas não calculam.
    def self.calculator(ctx = nil)
      calc = Dentaku::Calculator.new(case_sensitive: true)
      AGGREGATES.each do |name, agg|
        calc.add_function(name.to_sym, :numeric, lambda { |q|
          raise ArgumentError, "#{name} só funciona numa execução" unless ctx

          agg.call(ctx.query(q).map { |p| ctx.value(p) })
        })
      end
      # Lote 7: `defined('x')` (a variável/ponto tem valor) e
      # `integration_ok('tuya')` (as integrações daquele tipo no local estão conectadas).
      calc.add_function(:defined, :logical, ->(name) { ctx ? ctx.defined?(name) : false })
      calc.add_function(:to_timestamp, :numeric, ->(v) { timestamp(v) })
      calc.add_function(:integration_ok, :logical, lambda { |key|
        list = ctx ? ctx.site.integrations.select { |i| i.plugin&.key == key.to_s } : []
        list.any? && list.all? { |i| i.status == "ok" }
      })
      calc
    end

    # Número, data e hora ou texto ISO ("2026-10-31T08:00:00-03:00") → segundos desde 1970 (0 = sem data).
    def self.timestamp(v)
      return v if v.is_a?(Numeric)
      return v.to_i if v.respond_to?(:to_time) && !v.is_a?(String)

      Time.zone.parse(v.to_s)&.to_i || 0
    rescue ArgumentError
      0
    end
  end
end
