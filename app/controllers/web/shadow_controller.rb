module Web
  # Sombra do local (F10): a linha do tempo do que as automações em sombra
  # teriam feito (filtros por automação, tipo e período), o de-para da
  # migração e os relatórios do comparador (tela e CSV). Ver: qualquer
  # papel. Ligar/desligar a sombra do local: dono. Comparar agora: técnico+.
  class ShadowController < ApplicationController
    WINDOWS = { "6" => "6 horas", "24" => "24 horas", "72" => "3 dias", "168" => "7 dias" }.freeze

    def show
      load_site(:view)
      @hours = params[:horas].presence_in(WINDOWS.keys) || "24"
      scope = ShadowAction.where(site_id: @site.id, created_at: @hours.to_i.hours.ago..).includes(:automation, :scene).recent
      scope = scope.where(automation_id: params[:automacao]) if params[:automacao].present?
      scope = scope.where(action: params[:tipo]) if params[:tipo].present?
      @pagy, @actions = pagy(scope, limit: 50)
      @origins = Automation.where(id: ShadowAction.where(site_id: @site.id).select(:automation_id)).order(:name).pluck(:name, :id)
      @types = ShadowAction.where(site_id: @site.id).distinct.order(:action).pluck(:action)
      @reports = ShadowReport.where(site_id: @site.id).recent.limit(8).to_a
      @site_shadow = Shadow.site?(@site)
      all = Automation.where(site_id: @site.id)
      @in_shadow = @site_shadow ? all.count : all.where(shadow: true).count
      @live = @site_shadow ? 0 : all.where(enabled: true, shadow: false).count
      @refs = ExternalRef.where(site_id: @site.id).group(:source, :kind).count
      @unmapped = ExternalRef.where(site_id: @site.id, target_id: nil).order(:external_id).limit(50).to_a
      @sources = Shadow::Compare.sources.filter_map { |p| [ p, @site.integrations.find_by(driver: p.driver) ] }
    end

    def update
      load_site(:admin)
      on = ActiveModel::Type::Boolean.new.cast(params[:shadow])
      @site.update!(shadow: on)
      redirect_to site_shadow_path(@site), notice: on ? "Local em sombra: nenhuma automação, cena ou regra comanda aparelho." : "Sombra do local desligada. Vale a marca de cada automação."
    end

    def compare
      load_site(:manage)
      plugin = Shadow::Compare.source(params[:fonte]) or return redirect_to(site_shadow_path(@site), alert: "Fonte de referência desconhecida.")
      hours = params[:horas].presence_in(WINDOWS.keys).to_i.nonzero? || 24
      report = Shadow::Compare.call(@site, plugin.key, from: hours.hours.ago, to: Time.current)
      redirect_to report_site_shadow_path(@site, report.id), notice: "Comparação pronta."
    rescue Integrations::Error, ArgumentError => e
      redirect_to site_shadow_path(@site), alert: "Não comparei: #{e.message}"
    end

    def report
      load_site(:view)
      @report = ShadowReport.where(site_id: @site.id).find(params[:report_id])
      @status = params[:status].presence_in(ShadowReport::STATUSES.keys)
      @rows = @status ? @report.rows.select { |r| r["status"] == @status } : @report.rows
      respond_to do |format|
        format.html
        format.csv { send_data @report.to_csv, filename: "comparacao-#{@report.created_at.to_date}.csv", type: "text/csv" }
      end
    end

    private

    def load_site(action)
      @site = Site.find(params[:site_id])
      authorize_site!(@site, action)
    end
  end
end
