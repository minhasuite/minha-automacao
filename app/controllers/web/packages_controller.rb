module Web
  # Loja de pacotes do local (Pacote 3, Packages): instalar por URL com
  # pré-visualização, ver o que entrou, procurar versão nova e remover.
  # Ver: qualquer papel; instalar, atualizar e remover: técnico ou dono.
  class PackagesController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @packages = @site.packages.ordered
      @tab = params[:tab] == "explorar" ? "explore" : "installed"
      return unless @tab == "explore"

      # Aba "Explorar": o catálogo (Packages::Catalog); instalar segue pela prévia de sempre.
      @catalog = Packages::Catalog.call
      @tags = @catalog.entries.flat_map(&:tags).tally.sort_by { |t, n| [ -n, t ] }.first(12).map(&:first)
      @entries = Packages::Catalog.search(@catalog.entries, q: params[:q], tag: params[:tag])
      @installed = @packages.to_h { |pk| [ pk.key, pk ] }
    end

    def show
      load_package(:view)
    end

    # URL → manifesto validado e o plano (o que entra), sem gravar nada.
    def preview
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @url = params[:url].to_s.strip
      @manifest, @source = Packages.fetch(@url)
      @existing = @site.packages.find_by(key: @manifest["key"])
      @errors = Packages.errors(@manifest, @site)
      @plan = Packages.preview(@site, @manifest, @existing)
      render :preview
    rescue Packages::Error => e
      redirect_to site_packages_path(@site, url: @url), alert: e.message
    end

    def install
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      manifest, source = Packages.fetch(params[:url])
      package = Packages.install!(@site, manifest, source)
      redirect_to package_path(package), notice: t("packages.flash.installed", name: package.name, version: package.version)
    rescue Packages::Error, ActiveRecord::RecordInvalid => e
      redirect_to site_packages_path(@site, url: params[:url]), alert: e.message.truncate(300)
    end

    # Procura versão nova e mostra o plano da atualização.
    def check
      load_package(:manage)
      @manifest, @source, @newer = Packages.check(@package)
      @errors = Packages.errors(@manifest, @site)
      @plan = Packages.preview(@site, @manifest, @package)
      @existing = @package
      @url = @package.source_url
      render :preview
    rescue Packages::Error => e
      redirect_to package_path(@package), alert: e.message
    end

    def destroy
      load_package(:manage)
      Packages.uninstall!(@package)
      redirect_to site_packages_path(@site), notice: t("packages.flash.removed", name: @package.name)
    end

    private

    def load_package(action)
      @package = Package.find(params[:id])
      @site = @package.site
      authorize_site!(@site, action)
    end
  end
end
