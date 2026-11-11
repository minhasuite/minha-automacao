module Web
  # Assistente do painel (ideia 8): cômodos + estilo + tema → painel pronto
  # (`Dashboards::Wizard`). Só técnico ou dono do local.
  class DashboardWizardController < ApplicationController
    before_action :load_site

    def new
      @areas = Dashboards::Wizard.areas(@site)
    end

    def create
      d = Dashboards::Wizard.create!(@site, name: params[:name], author: current_user, area_ids: Array(params[:areas]).compact_blank,
                                            theme: params[:theme], layout: params[:layout].presence_in(Dashboards::Wizard::LAYOUTS) || "columns")
      redirect_to dashboard_path(d), notice: t("arrange.wizard.created")
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to site_dashboard_wizard_path(@site), alert: e.message
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end
  end
end
