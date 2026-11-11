# Dashboards dirigidos pelo servidor (F5; visões com caminho na F8d).
module Dashboards
  # Visão pedida na URL (`?view=`): pelo caminho ou pelo id; sem pedido, a do
  # contexto (`open_view`, ideia 9: `open_if` do painel); senão a primeira.
  def self.pick_view(resolved, slug)
    views = resolved["views"]
    # Sem `?view=`: a do contexto (`open_if`, ideia 9), a inicial (`start_view`, ideia 17), a primeira.
    find = ->(s) { views.find { |v| s.present? && (v["path"] == s || v["id"] == s) } }
    find.call(slug) || (slug.blank? && (find.call(resolved["open_view"]) || find.call(resolved["start_view"]))) || views.first
  end
end
