# Dashboards dirigidos pelo servidor (F5; visões com caminho na F8d).
module Dashboards
  # Visão pedida na URL (`?view=`): pelo caminho ou pelo id; senão a primeira.
  def self.pick_view(resolved, slug)
    views = resolved["views"]
    # Sem `?view=`, a visão inicial do painel (`start_view`, ideia 17), senão a primeira.
    views.find { |v| slug.present? && (v["path"] == slug || v["id"] == slug) } ||
      views.find { |v| resolved["start_view"].present? && v["id"] == resolved["start_view"] } || views.first
  end
end
