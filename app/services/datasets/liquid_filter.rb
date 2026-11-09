module Datasets
  # Filtro Liquid `dataset_rows` (o `state_attr('sensor.x', 'lista')` do sensor
  # `sql` do HA): as linhas mais recentes de um conjunto do local, pela chave,
  # para o Texto do painel e os textos das automações.
  #
  #   {% assign acoes = "robo_historico" | dataset_rows: 10 %}
  #   {% for a in acoes %}**{{ a.em | date: "%d/%m %H:%M" }}** · {{ a.acao }}{% endfor %}
  #
  # Cada linha é `{id, em (ISO, no fuso do local), ...campos}`, como no
  # "Consultar dados". Segundo argumento opcional: os filtros da ação, um por
  # linha (`"tipo = erro"`). Até MAX linhas; conjunto que não existe = erro.
  module LiquidFilter
    MAX = 50

    def dataset_rows(input, limit = 10, filters = nil)
      ctx = @context.registers[:automation_context] or raise Liquid::Error, "dataset_rows fora de um texto do local"
      dataset = ctx.site.datasets.find_by(key: input.to_s.strip) or raise Liquid::Error, "conjunto de dados \"#{input}\" não existe neste local"
      Query.new(dataset, op: "rows", filters: filters, limit: limit.to_i.clamp(1, MAX), zone: ctx.now.time_zone).call
    rescue ArgumentError => e
      raise Liquid::Error, e.message
    end
  end
end
