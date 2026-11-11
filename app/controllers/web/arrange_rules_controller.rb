module Web
  # Configurações → Painéis → Arrumação do local (P2.1): as regras das visões
  # de cômodo (`arrange`) e do painel automático (`auto_rules`) como dado, em
  # `sites.settings["dashboard_defaults"]`. Só técnico ou dono. "Voltar ao
  # padrão" apaga só estas duas chaves (os outros padrões ficam).
  class ArrangeRulesController < ApplicationController
    before_action :load_site

    def edit
      @rules = Dashboards::Arrange.rules(@site)
      @auto = Dashboards::Arrange.auto_rules(@site)
      @custom = Dashboards::Arrange.defaults(@site).slice("arrange", "auto_rules").any?
    end

    def update
      defaults = Dashboards::Arrange.defaults(@site)
      if params[:reset].present?
        defaults = defaults.except("arrange", "auto_rules")
      else
        rules = Dashboards::Arrange.from_form(params.fetch(:arrange, {}).to_unsafe_h)
        auto = Dashboards::Arrange.auto_from_form(params.fetch(:auto, {}).to_unsafe_h)
        errors = Dashboards::Arrange.errors(rules) + Dashboards::Arrange.auto_errors(auto)
        return redirect_to(settings_arrange_rules_path(@site), alert: errors.first(3).to_sentence) if errors.any?

        defaults = defaults.merge("arrange" => (rules unless rules == Dashboards::Arrange::DEFAULT),
                                  "auto_rules" => (auto unless auto == Dashboards::Arrange::AUTO_DEFAULT)).compact
      end
      @site.update!(settings: @site.settings.to_h.merge("dashboard_defaults" => defaults.presence).compact)
      redirect_to settings_arrange_rules_path(@site), notice: t("arrange.rules.saved")
    rescue ArgumentError => e
      redirect_to settings_arrange_rules_path(@site), alert: e.message
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end
  end
end
