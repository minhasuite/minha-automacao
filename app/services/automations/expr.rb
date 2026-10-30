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
      calc
    end
  end
end
