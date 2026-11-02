module Web
  # Ferramentas de desenvolvedor do local (Pacote 3, DevTools): Estados,
  # Modelo (Liquid/expressão ao vivo), Ação (comando com confirmação, risco e
  # sombra) e Eventos (escutar e disparar). Só administrador ou dono.
  class DevToolsController < ApplicationController
    # Aba → rótulo em pt-BR (na tela: t("dev_tools.tabs.<aba>")).
    TABS = { "estados" => "Estados", "modelo" => "Modelo", "acao" => "Ação", "eventos" => "Eventos", "estatisticas" => "Estatísticas" }.freeze

    before_action :load_site

    def show
      @tab = TABS.key?(params[:aba]) ? params[:aba] : "estados"
      @states = DevTools.states(@site, q: params[:q], capability: params[:capacidade]) if @tab == "estados"
      @template = params[:template].presence || t("dev_tools.default_template")
      @writable = @site.points.where(writable: true, disabled: false).includes(:device).ordered if @tab == "acao"
    end

    def state
      point = @site.points.find(params[:point_id])
      DevTools.set_helper!(point, params[:value])
      redirect_to dev_tools_site_path(@site, aba: "estados", q: params[:q]), notice: "#{point.name}: #{helpers.point_value_text(point)}."
    rescue Points::Command::Error => e
      redirect_to dev_tools_site_path(@site, aba: "estados", q: params[:q]), alert: e.message
    end

    # Testador ao vivo: responde só o quadro do resultado.
    def template
      @template = params[:template].to_s
      @mode = params[:mode] == "expr" ? "expr" : "liquid"
      @result, @error = DevTools.render(@site, @template, mode: @mode)
      render partial: "web/dev_tools/result", locals: { result: @result, error: @error, mode: @mode }
    end

    def command
      point = @site.points.find(params[:point_id])
      authorize_site!(@site, :command, risk: point.risk)
      c = DevTools.command!(point, params[:command].to_s, params[:value], user: current_user)
      msg = c.error ? "#{point.name}: #{c.error}" : "#{point.name}: #{Points::Timeline::COMMAND_LABELS.fetch(c.command, c.command)} (#{c.status})."
      redirect_to dev_tools_site_path(@site, aba: "acao"), (c.error ? :alert : :notice) => msg
    rescue Points::Command::Error => e
      redirect_to dev_tools_site_path(@site, aba: "acao"), alert: e.message
    end

    def event
      name = DevTools.fire!(@site, params[:event], params[:data])
      redirect_to dev_tools_site_path(@site, aba: "eventos"), notice: t("dev_tools.fired", name: name)
    rescue ArgumentError => e
      redirect_to dev_tools_site_path(@site, aba: "eventos"), alert: e.message
    end

    def stats_adjust
      point = @site.points.find(params[:point_id])
      at = DevTools::Statistics.adjust!(point, params[:at], params[:sum])
      redirect_to dev_tools_site_path(@site, aba: "estatisticas"), notice: t("dev_tools.stats.adjusted", name: point.name, at: l(at, format: :short))
    rescue ArgumentError => e
      redirect_to dev_tools_site_path(@site, aba: "estatisticas"), alert: e.message
    end

    def stats_purge
      point = @site.points.find(params[:point_id])
      n = DevTools::Statistics.purge!(point)
      redirect_to dev_tools_site_path(@site, aba: "estatisticas"), notice: t("dev_tools.stats.purged", name: point.name, n: n)
    end

    private

    def load_site
      @site = Site.find(params[:id])
      authorize_site!(@site, :view)
      raise ActiveRecord::RecordNotFound unless DevTools.admin?(current_user) # membro comum nem vê que existe
    end
  end
end
