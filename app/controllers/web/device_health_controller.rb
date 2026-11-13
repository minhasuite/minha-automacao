module Web
  # Saúde dos aparelhos (docs/saude-aparelhos.md): os achados do
  # `Diagnostics` de um local, agrupados por problema ou por área, com filtros,
  # reparos seguros, silenciar por X dias e os ajustes do local (limiares).
  # Ver: técnico para cima (é diagnóstico de cadastro); cada reparo pede o papel dele.
  class DeviceHealthController < ApplicationController
    FILTERS = %i[problema area severidade agrupar silenciados].freeze

    def show
      return redirect_to(sites_path, notice: t("device_health.need_site")) unless pick_site

      @all = Diagnostics.run(@site)
      @findings = filtered(@all)
      @group = params[:agrupar] == "area" ? "area" : "rule"
      @settings = Diagnostics.settings(@site)
      @areas = @site.areas.order(:name).to_a
      @reveal = reveal_sensitive?
    end

    # Um reparo do achado: o achado é refeito agora (o reparo só vale se ainda se aplica).
    def fix
      load_site!
      finding = Diagnostics.run(@site).find { |f| f.ref == params[:ref].to_s } or return back(alert: t("device_health.gone"))
      fix = Diagnostics.fix(params[:fix])
      return back(alert: t("device_health.no_fix")) unless fix && fix.kind != :link && finding.fixes.include?(fix.key)
      raise SiteMembership::Forbidden, t("notices.forbidden") unless fix.allowed?(@site_role)

      back(notice: fix.call(finding, user: current_user, params: params.permit(:area_id)))
    rescue Diagnostics::Error, ::Integrations::Error => e
      back(alert: e.message)
    end

    # Silenciar (dias) ou voltar a mostrar (`on=0`) um achado.
    def snooze
      load_site!
      if params[:on] == "0"
        Diagnostics.unsnooze!(@site, params[:ref])
        back(notice: t("device_health.unsnoozed"))
      else
        at = Diagnostics.snooze!(@site, params[:ref], params[:days], user: current_user)
        back(notice: t("device_health.snoozed", date: l(at.to_date)))
      end
    rescue Diagnostics::Error
      back(alert: t("device_health.bad_days"))
    end

    # Ajustes do local (limiar de bateria, aviso, horas sem sinal).
    def update_settings
      load_site!
      Diagnostics.update_settings!(@site, params.fetch(:settings, {}).permit(*Diagnostics.config.fetch("editable").keys).to_h)
      back(notice: t("device_health.settings_saved"))
    end

    private

    # Só os locais em que a pessoa cadastra (técnico+); o do parâmetro, o do Início ou o primeiro.
    def pick_site
      @sites = Site.visible_to(current_user).order(:name).select { |s| SiteMembership.allowed?(s.role_for(current_user), :manage) }
      @site = @sites.find { |s| s.id == params[:site_id] } || @sites.find { |s| s.id == current_user.dashboard_prefs["site"] } || @sites.first
      authorize_site!(@site, :manage) if @site
      @site
    end

    def load_site!
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end

    def back(**flash) = redirect_to(device_health_path(site_id: @site.id, **params.permit(*FILTERS).to_h.symbolize_keys), **flash)

    def filtered(all)
      list = params[:silenciados] == "1" ? all : all.reject(&:snoozed?)
      list = list.select { |f| f.rule.key == params[:problema] } if params[:problema].present?
      list = list.select { |f| f.severity == params[:severidade] } if params[:severidade].present?
      if params[:area].present?
        list = list.select { |f| params[:area] == "none" ? f.area.nil? : f.area&.id == params[:area] }
      end
      list.sort_by { |f| [ -Diagnostics::SEVERITIES.index(f.severity), f.rule.key, f.name.to_s.downcase ] }
    end
  end
end
