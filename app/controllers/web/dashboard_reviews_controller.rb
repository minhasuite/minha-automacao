module Web
  # Revisar e publicar (ideias 24 e 25): o rascunho em celular, tablet e
  # computador, no claro e no escuro (iframes do próprio painel em `?embed=1`,
  # sem desenhar duas vezes aqui), os avisos que não bloqueiam (Dashboards::Lint,
  # com o link para corrigir) e o botão de publicar.
  class DashboardReviewsController < ApplicationController
    include DashboardEditing

    THEMES = %w[light dark].freeze
    SCREENS = { "mobile" => 390, "tablet" => 768, "desktop" => 1280 }.freeze

    def show
      load_dashboard(:manage)
      @draft = @dashboard.working_draft
      @view = Dashboards.pick_view(@draft, params[:view])
      @theme = params[:tema].presence_in(THEMES) || "light"
      @warnings = Dashboards::Lint.call(@site, @draft)
      @changes = Dashboards::Diff.count(Dashboards::Diff.call(@dashboard.published, @draft))
    end
  end
end
