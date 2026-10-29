module Automations
  # Calculadora das expressões (dentaku): só aritmética, comparação, lógica e
  # funções do dentaku (if, round, min, max...), sem código arbitrário.
  module Expr
    def self.calculator = Dentaku::Calculator.new(case_sensitive: true)
  end
end
