# O que os controllers do editor de painel dividem (DashboardsController e os
# da agilidade do editor: widget, versões, revisão): achar o painel com o papel,
# voltar para onde a pessoa estava (o editor ou a edição na própria tela,
# `back=painel`) e gravar o rascunho com a pilha de desfazer.
module DashboardEditing
  extend ActiveSupport::Concern

  included { helper_method :editor_path }

  # Rótulo do passo na pilha de desfazer, pela op do editor.
  OPS = %w[add_view update_view add_section update_section add_widget update_widget move place theme resize remove duplicate paste paste_style
           json widget_json discard add_to].freeze

  private

  def load_dashboard(action)
    @dashboard = Dashboard.find(params[:id])
    @site = @dashboard.site
    authorize_site!(@site, action)
    raise ActiveRecord::RecordNotFound unless @dashboard.visible_to?(@site_role)
  end

  # Ideia 1: na edição na própria tela (`back=painel`) a volta é o painel em modo editar.
  def editor_path(view: params[:view_id], w: nil, anchor: nil)
    return dashboard_path(@dashboard, editar: 1, view: view.presence) if params[:back] == "painel"

    edit_dashboard_path(@dashboard, view: view.presence, w: w, anchor: anchor)
  end

  def store_draft(definition, op)
    @dashboard.save_draft!(definition, label: (I18n.t("dashboards.history.ops.#{op}") if OPS.include?(op.to_s)))
  end

  # Pontos, áreas e cenas que os formulários de widget pedem.
  def load_form_options
    @points = @site.points.includes(:device).order(:name).to_a
    @areas = @site.areas.order(:position, :name).to_a
    @scenes = @site.scenes.order(:name).to_a
  end
end
