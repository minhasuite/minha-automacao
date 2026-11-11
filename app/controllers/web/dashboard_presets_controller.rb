module Web
  # Predefinições de painel (Dashboards::Presets): escolher, preencher os
  # pontos e criar o painel publicado. Técnico ou dono. P2.2/ideia 20: além
  # das classes, a biblioteca embutida e os itens `preset` dos pacotes do
  # local. P2.3: importar o pacote exportado (arquivo JSON/YAML) pelo caminho
  # de sempre (`Packages.install!`) e ir mapear as entradas.
  class DashboardPresetsController < ApplicationController
    MAX_FILE = Packages::MAX_BYTES

    before_action :load_site

    def index
      @presets = Dashboards::Presets.all(@site)
    end

    def new
      @kind = Dashboards::Presets.find(@site, params[:key]) or raise ActiveRecord::RecordNotFound
      @form = {}
    end

    def create
      @kind = Dashboards::Presets.find(@site, params[:key]) or raise ActiveRecord::RecordNotFound
      @form = params.fetch(:preset, {}).permit(:name, *@kind.fields.map { |f| f.kind == :points ? { f.key => [] } : f.key }).to_h
      dashboard, @errors = Dashboards::Presets.create!(@site, @kind, @form)
      return render(:new, status: :unprocessable_content) unless dashboard

      redirect_to dashboard_path(dashboard), notice: t("dashboards.flash.preset_created", name: dashboard.name)
    end

    # Arquivo do "Exportar como pacote" → instala (modelos e painel pronto) → o formulário das entradas.
    def import
      file = params[:file]
      raise Packages::Error, t("dashboards.presets.import_file") unless file.respond_to?(:read) && file.size.between?(1, MAX_FILE)

      name = File.basename(file.original_filename.to_s).first(80)
      manifest = Packages.parse(file.read, name)
      package = Packages.install!(@site, manifest, "arquivo:#{name}")
      preset = Dashboards::Presets.from_packages(@site).find { |p| p.package == package }
      redirect_to(preset ? site_dashboard_preset_path(@site, preset.key) : site_card_templates_path(@site),
                  notice: t("packages.flash.installed", name: package.name, version: package.version))
    rescue Packages::Error, ActiveRecord::RecordInvalid => e
      redirect_back_or_to site_dashboard_presets_path(@site), alert: e.message.truncate(300)
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end
  end
end
