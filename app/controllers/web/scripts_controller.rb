module Web
  # Scripts (F8f): lista e criação. O resto (editor, campos, versões,
  # executar, execuções) é o das automações (AutomationsController), porque
  # script é automação de `kind: "script"`.
  class ScriptsController < ApplicationController
    before_action :load_site

    def index
      authorize_site!(@site, :view)
      scope = @site.scripts.includes(:area).ordered
      scope = scope.where("automations.name ILIKE ?", "%#{Automation.sanitize_sql_like(params[:q].to_s.strip)}%") if params[:q].present?
      scope = scope.labeled(params[:rotulo]) if params[:rotulo].present?
      @labels = Automation.labels_in(@site.scripts)
      @total = @site.scripts.count
      @scripts = scope.includes(:tags).to_a
    end

    def new
      authorize_site!(@site, :manage)
      @automation = @site.scripts.new(mode: "single")
      render "web/automations/new"
    end

    def create
      authorize_site!(@site, :manage)
      @automation = @site.scripts.new(params.require(:automation).permit(:name, :description, :mode, :max_runs, :area_id, :icon))
      return render("web/automations/new", status: :unprocessable_content) unless @automation.save

      redirect_to edit_automation_path(@automation), notice: t("automations.flash.script_created")
    end

    private

    def load_site = @site = Site.find(params[:site_id])
  end
end
