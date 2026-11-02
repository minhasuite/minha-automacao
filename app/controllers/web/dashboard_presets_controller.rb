module Web
  # Predefinições de painel (Dashboards::Presets): escolher, preencher os
  # pontos e criar o painel publicado. Técnico ou dono.
  class DashboardPresetsController < ApplicationController
    before_action :load_site

    def index
      @presets = Dashboards::Presets.plugins
    end

    def new
      @kind = Dashboards::Presets[params[:key]] or raise ActiveRecord::RecordNotFound
      @form = {}
    end

    def create
      @kind = Dashboards::Presets[params[:key]] or raise ActiveRecord::RecordNotFound
      @form = params.fetch(:preset, {}).permit(:name, *@kind.fields.map { |f| f.kind == :points ? { f.key => [] } : f.key }).to_h
      dashboard, @errors = Dashboards::Presets.create!(@site, @kind, @form)
      return render(:new, status: :unprocessable_content) unless dashboard

      redirect_to dashboard_path(dashboard), notice: t("dashboards.flash.preset_created", name: dashboard.name)
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end
  end
end
