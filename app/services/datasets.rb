# Consultas sobre conjuntos de dados (Lote 2) como plugins: cada tipo de
# consulta é uma classe em Datasets::Aggregates registrada em AGGREGATES
# (`key`, `label`, `needs_field?`, `scalar?`, `call(scope, field, limit, zone)`),
# e cada operador de filtro uma classe em Datasets::Operators registrada em
# OPERATORS (`symbol`, `apply(scope, field, value)`). A ação "Consultar
# dados", o helper Consulta e a tela perguntam ao registro; nada de `case`
# por tipo. SQL livre não existe (nem modo "somente leitura"): só estes
# tipos, com o campo sempre como parâmetro.
module Datasets
  AGGREGATES = %w[Count Sum Avg Min Max Last Rows].freeze
  OPERATORS = %w[Gte Lte NotEq Eq Gt Lt Contains].freeze

  module_function

  def aggregates = AGGREGATES.map { |name| Aggregates.const_get(name) }
  def aggregate(key) = aggregates.find { |a| a.key == key.to_s }
  def choices = aggregates.to_h { |a| [ a.key, a.label ] }
  # Os que dão um valor só (o helper Consulta vira ponto com ele).
  def scalar_choices = aggregates.select(&:scalar?).to_h { |a| [ a.key, a.label ] }
  def operators = OPERATORS.map { |name| Operators.const_get(name) }

  # "campo = valor" por linha → [[operador, campo, valor]]. Linha que não
  # serve = ArgumentError com a linha.
  def parse_filters(text)
    ops = operators.sort_by { |o| -o.symbol.size }
    pattern = /\A([a-z_][a-z0-9_]*)\s*(#{ops.map { |o| Regexp.escape(o.symbol) }.join('|')})\s*(.*)\z/i
    text.to_s.lines.map(&:strip).compact_blank.first(10).map do |line|
      m = pattern.match(line) or raise ArgumentError, "filtro inválido \"#{line.truncate(40)}\" (use campo = valor, campo contém x, campo > 3)."
      [ ops.find { |o| o.symbol.casecmp?(m[2]) }, m[1], m[3].strip ]
    end
  end
end
