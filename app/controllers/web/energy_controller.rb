module Web
  # Energia por aparelho: consumo e custo (dia, semana, mês) pela tarifa do
  # local, ranking, comparação com o mesmo trecho do período anterior, a média
  # aprendida por hora e o aviso de consumo fora do normal (`EnergyUse`,
  # `EnergyWatchJob`). Ver: qualquer papel do local; mudar a tarifa e a regra
  # do aviso: técnico+. Ver docs/energia.md.
  class EnergyController < ApplicationController
    include SitePick

    def show
      return redirect_to(sites_path, notice: t("notices.need_site_energy")) unless pick_site

      @period = params[:periodo].presence_in(EnergyUse::PERIODS.keys) || "month"
      @report = EnergyUse.report(@site, period: @period)
      @anomalies = EnergyUse.anomalies(@site)
      @watch = EnergyUse.watch(@site)
      @tariff_point = EnergyUse.tariff_point(@site)
      @tariff = EnergyUse.tariff(@site)
      @manage = can?(:manage)
    end

    def update
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      errors = EnergyUse.update!(@site, params.fetch(:energy, {}).permit(:tariff_point, :tariff, :enabled, :factor, :min_kwh, ignore: []))
      return redirect_to(energy_path(site_id: @site.id, anchor: "regra"), alert: errors.to_sentence) if errors.any?

      AuditEvent.create!(tenant_id: current_user.tenant_id, user_id: current_user.id, action: "energy.settings", auditable_type: "Site",
                         auditable_id: @site.id, details: EnergyUse.settings(@site))
      redirect_to energy_path(site_id: @site.id, anchor: "regra"), notice: t("energy.saved")
    end
  end
end
