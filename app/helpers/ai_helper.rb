module AiHelper
  # Custo estimado em dólar (os provedores cobram em US$): 4 casas abaixo de 1.
  def usd(value)
    v = value.to_f
    number_to_currency(v, unit: "US$", separator: ",", delimiter: ".", precision: v.positive? && v < 1 ? 4 : 2)
  end
end
