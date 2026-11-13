# Dashboards dirigidos pelo servidor (F5; visões com caminho na F8d).
module Dashboards
  # visao-entrega: chaves do `visible_if` que valem numa visão (as que não mudam com o tempo:
  # papel, tela e aparelho). Estado, hora, sol etc. ficam nos widgets.
  VIEW_VISIBILITY = %w[role screen device].freeze

  # Visão pedida na URL (`?view=`): pelo caminho ou pelo id; sem pedido, a do
  # contexto (`open_view`, ideia 9: `open_if` do painel); senão a primeira.
  def self.pick_view(resolved, slug)
    views = resolved["views"]
    # Sem `?view=`: a do contexto (`open_if`, ideia 9), a inicial (`start_view`, ideia 17), a primeira.
    find = ->(s) { views.find { |v| s.present? && (v["path"] == s || v["id"] == s) } }
    find.call(slug) || (slug.blank? && (find.call(resolved["open_view"]) || find.call(resolved["start_view"]))) || views.first
  end

  # `visible_if.role` de widget ou visão: sem lista = todos; o dono vê tudo.
  def self.role_ok?(cond, role)
    roles = cond.is_a?(Hash) ? cond["role"] : nil
    roles.nil? || role == "owner" || Array(roles).include?(role)
  end

  # visao-entrega: telas em que a visão aparece (`visible_if.screen`); vazio = todas.
  def self.view_screens(view) = Array(view.is_a?(Hash) ? view.dig("visible_if", "screen") : nil) & Schema::SCREENS

  def self.view_shown_on?(view, screen) = (s = view_screens(view)).empty? || s.include?(screen)
end
