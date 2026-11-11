module Web
  # Ideia 5: desfazer/refazer no rascunho (Dashboards::History) e comparar
  # duas versões lado a lado (Dashboards::Diff). Técnico ou dono.
  class DashboardVersionsController < ApplicationController
    include DashboardEditing

    DRAFT = "rascunho".freeze

    def undo = step(:undo!)
    def redo = step(:redo!)

    # `a` e `b`: número da versão ou "rascunho". Padrão: a publicada × o rascunho (ou a anterior).
    def compare
      load_dashboard(:manage)
      @versions = @dashboard.versions.includes(:author).limit(50).to_a
      @choices = [ ([ t("dashboards.cmp.draft"), DRAFT ] if @dashboard.draft?), *@versions.map { |v| [ t("dashboards.cmp.version", n: v.version), v.version.to_s ] } ].compact
      @a = params[:a].presence || (@dashboard.draft? ? @dashboard.version.to_s : @versions.second&.version.to_s)
      @b = params[:b].presence || (@dashboard.draft? ? DRAFT : @dashboard.version.to_s)
      @diff = Dashboards::Diff.call(definition(@a), definition(@b), names: @site.points.pluck(:id, :name).to_h) if @a.present? && @b.present?
    end

    private

    def step(method)
      load_dashboard(:manage)
      done = Dashboards::History.public_send(method, @dashboard)
      key = done ? "#{method.to_s.delete('!')}_done" : "#{method.to_s.delete('!')}_empty"
      redirect_to editor_path, (done ? :notice : :alert) => t("dashboards.history.#{key}")
    end

    def definition(ref)
      return @dashboard.working_draft if ref == DRAFT

      (@versions.find { |v| v.version.to_s == ref } || @dashboard.versions.find_by(version: ref.to_i))&.definition || {}
    end
  end
end
