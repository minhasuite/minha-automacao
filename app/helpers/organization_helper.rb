# ondaA1 (A2): rótulos e categorias nas listas (automações, scripts, cenas,
# helpers) e nos formulários.
module OrganizationHelper
  # [[categoria ou nil, itens]], sem categoria por último. Lista sem nenhuma
  # categoria = um grupo só (nil), e a tela não mostra cabeçalho.
  def category_groups(list)
    groups = list.group_by { |x| x.category.presence }
    return [ [ nil, list ] ] if groups.keys.compact.empty?

    groups.sort_by { |k, _| [ k.nil? ? 1 : 0, k.to_s.downcase ] }
  end

  # Categorias já usadas nesta lista (sugestões do campo).
  def category_options(scope) = scope.where.not(category: nil).distinct.order(:category).pluck(:category)

  def label_chips(record)
    safe_join(record.tags.sort_by(&:name).map do |t|
      tag.span(t.name, class: "ss-label-chip", style: ("--c: #{t.color}" if t.color.to_s.match?(/\A#\h{6}\z/)))
    end, " ")
  end
end
