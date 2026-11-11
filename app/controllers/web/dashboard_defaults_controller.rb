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
      @quick = Dashboards::Actions.quick_list(@site, { "type" => AREA })
    end

    def update
      defaults = @site.settings.to_h.fetch("dashboard_defaults", {})
      if params[:reset].present?
        defaults = {}
      else
        facts = Dashboards::Facts.from_form(form_rows(:facts, Dashboards::Facts::FORM_FIELDS))
        errors = Dashboards::Facts.errors(facts)
        return redirect_to(settings_dashboard_defaults_path(@site), alert: errors.first(3).to_sentence) if errors.any?

        quick = quick_from_form
        errors = Dashboards::Actions.quick_errors(Dashboards::Actions::QUICK => quick) if quick
        return redirect_to(settings_dashboard_defaults_path(@site), alert: errors.first(3).to_sentence) if errors.present?

        defaults = defaults.merge("area_facts" => facts.presence, "stale_after_min" => Dashboards::Staleness.from_form(form_rows(:stale, %i[key min])),
                                  "quick_actions" => ({ AREA => quick } if quick)).compact
      end
      @site.update!(settings: @site.settings.to_h.merge("dashboard_defaults" => defaults.presence).compact)
      redirect_to settings_dashboard_defaults_path(@site), notice: t("dashboard_defaults.saved")
    end

    private

    AREA = "area_card"

    # Ideia 12: botões rápidos do cartão de área (lote por consulta), linha a linha.
    def quick_from_form
      form_rows(:quick, %i[label icon query command value]).values.filter_map do |r|
        next if r["label"].blank? || r["query"].blank?

        { "action" => "command_query", "label" => r["label"].strip, "icon" => r["icon"].presence, "query" => r["query"].strip,
          "command" => r["command"].to_s, "value" => r["value"].presence }.compact
      end.presence
    end

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end
  end
end
