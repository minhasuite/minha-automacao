module Web
  # "Adicionar ao painel" (ideia 2): escolhe painel + visão + seção e cria o
  # widget certo (Dashboards::AddTo) no RASCUNHO; publicar continua no editor.
  # Técnico ou dono do local da coisa.
  class DashboardAddsController < ApplicationController
    include DashboardEditing

    def new
      load_source
      @places = Dashboards::AddTo.places(@dashboards)
    end

    def create
      load_source
      dashboard_id, section_id = params[:place].to_s.split(":", 2)
      @dashboard = @dashboards.find { |d| d.id == dashboard_id } or raise ActiveRecord::RecordNotFound
      editor = Dashboards::Editor.new(@dashboard.working_draft)
      w = editor.add_widget(section_id.to_s, @widget)
      errors = Dashboards::Schema.errors(editor.definition)
      return redirect_to(new_dashboard_add_path(tipo: @type, id: @record.id), alert: errors.first(3).to_sentence) if errors.any?

      store_draft(editor.definition, "add_to")
      view = Array(editor.definition["views"]).find { |v| Array(v["sections"]).any? { |s| s["id"] == section_id } }
      redirect_to edit_dashboard_path(@dashboard, view: view&.dig("id"), w: w, anchor: w), notice: t("dashboards.add_to.added", name: @dashboard.name)
    rescue KeyError
      redirect_to new_dashboard_add_path(tipo: @type, id: @record.id), alert: t("dashboards.flash.gone")
    end

    private

    def load_source
      @type = params[:tipo].to_s.presence_in(Dashboards::AddTo.types) or raise ActiveRecord::RecordNotFound
      @record = Dashboards::AddTo.find(@type, params[:id]) or raise ActiveRecord::RecordNotFound
      @site = @record.site
      authorize_site!(@site, :manage)
      @widget = Dashboards::AddTo.widget(@type, @record) or raise ActiveRecord::RecordNotFound
      @dashboards = Dashboard.ensure_for(@site).select { |d| d.visible_to?(@site_role) }
    end
  end
end
