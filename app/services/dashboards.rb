# Dashboards dirigidos pelo servidor (F5; visões com caminho na F8d).
module Dashboards
  # Visão pedida na URL (`?view=`): pelo caminho ou pelo id; senão a primeira.
  def self.pick_view(resolved, slug)
    views = resolved["views"]
    views.find { |v| slug.present? && (v["path"] == slug || v["id"] == slug) } || views.first
  end
end
