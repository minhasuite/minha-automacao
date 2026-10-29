module Web
  # Execuções de uma automação e o trace de cada uma (qualquer papel no local).
  class AutomationRunsController < ApplicationController
    def index
      @automation = Automation.find(params[:automation_id])
      @site = @automation.site
      authorize_site!(@site, :view)
      @pagy, @runs = pagy(@automation.runs.recent, limit: 30)
    end

    def show
      @run = AutomationRun.find(params[:id])
      @automation = @run.automation
      @site = @run.site
      authorize_site!(@site, :view)
    end
  end
end
