module Web
  # Configurações → Painéis → Padrões do local (P1.1 e ideia 22 da proposta de
  # personalização): os itens do cartão de área como consultas
  # (`Dashboards::Facts`) e o limite do selo "dado velho" por tipo
  # (`Dashboards::Staleness`), em `sites.settings["dashboard_defaults"]`. Só
  # técnico ou dono do local. "Voltar ao padrão" apaga o que foi gravado.
  class DashboardDefaultsController < ApplicationController
    before_action :load_site

    def edit
      @facts = Dashboards::Facts.area_defaults(@site)
      @stale = Dashboards::Staleness.limits(@site)
    end

    def update
      defaults = @site.settings.to_h.fetch("dashboard_defaults", {})
      if params[:reset].present?
        defaults = {}
      else
        facts = Dashboards::Facts.from_form(form_rows(:facts, Dashboards::Facts::FORM_FIELDS))
        errors = Dashboards::Facts.errors(facts)
        return redirect_to(settings_dashboard_defaults_path(@site), alert: errors.first(3).to_sentence) if errors.any?

        defaults = defaults.merge("area_facts" => facts.presence, "stale_after_min" => Dashboards::Staleness.from_form(form_rows(:stale, %i[key min]))).compact
      end
      @site.update!(settings: @site.settings.to_h.merge("dashboard_defaults" => defaults.presence).compact)
      redirect_to settings_dashboard_defaults_path(@site), notice: t("dashboard_defaults.saved")
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end
  end
end
