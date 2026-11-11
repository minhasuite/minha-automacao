module Web
  # Ideia 19: estilo dos cards do painel em um clique (Dashboards::CardStyles).
  # Vira versão publicada nova (e entra no rascunho, se houver), como o resto
  # do painel; vazio volta ao normal. Técnico ou dono.
  class DashboardCardStylesController < ApplicationController
    def update
      dashboard = Dashboard.find(params[:id])
      authorize_site!(dashboard.site, :manage)
      key = params[:card_style].presence
      raise ActiveRecord::RecordNotFound if key && !Dashboards::CardStyles[key]

      apply = ->(d) { key ? d.merge("card_style" => key) : d.except("card_style") }
      draft = dashboard.draft && apply.(dashboard.draft)
      dashboard.publish!(apply.(dashboard.published))
      dashboard.save_draft!(draft, label: t("dashboards.card_styles.title")) if draft
      label = key ? Dashboards::CardStyles.label(Dashboards::CardStyles[key]) : t("dashboards.card_styles.none")
      redirect_back_or_to edit_dashboard_path(dashboard), notice: t("dashboards.card_styles.applied", name: label)
    end
  end
end
