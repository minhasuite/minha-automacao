# Formatação de centavos em reais (pt-BR). Só exibição: conta é sempre em
# centavos inteiros.
module Money
  module_function

  def format(cents)
    return "" if cents.nil?

    ActiveSupport::NumberHelper.number_to_currency(cents / 100.0, unit: "R$ ", separator: ",", delimiter: ".", format: "%u%n")
  end
end
