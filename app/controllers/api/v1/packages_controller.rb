module Api
  module V1
    # Loja de pacotes (Pacote 3, Packages). Ver: qualquer papel no local;
    # pré-visualizar, instalar, atualizar e remover: técnico ou dono. Nunca
    # executa nada do pacote: os itens viram registros validados.
    class PackagesController < BaseController
      self.key_actions = { index: "read", show: "read" }

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        render_data(site.packages.ordered.map { |p| payload(p) })
      end

      def show = render_data(payload(load_package(:view), full: true))

      # POST /sites/:site_id/packages/preview { url } → manifesto, erros e plano.
      def preview
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        manifest, source = Packages.fetch(params.require(:url))
        existing = site.packages.find_by(key: manifest["key"])
        render_data({ "source_url" => source, "manifest" => manifest.slice("key", "name", "version", "description", "author"),
                      "installed_version" => existing&.version, "errors" => Packages.errors(manifest, site),
                      "plan" => Packages.preview(site, manifest, existing) })
      rescue Packages::Error => e
        render_error(:invalid_package, e.message, status: :unprocessable_content)
      end

      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        manifest, source = Packages.fetch(params.require(:url))
        render_data(payload(Packages.install!(site, manifest, source), full: true), status: :created)
      rescue Packages::Error => e
        render_error(:invalid_package, e.message, status: :unprocessable_content)
      end

      # PATCH /packages/:id → busca a fonte de novo e instala a versão de lá.
      def update
        package = load_package(:manage)
        manifest, source = Packages.fetch(package.source_url)
        render_data(payload(Packages.install!(package.site, manifest, source), full: true))
      rescue Packages::Error => e
        render_error(:invalid_package, e.message, status: :unprocessable_content)
      end

      def destroy
        Packages.uninstall!(load_package(:manage))
        head :no_content
      end

      private

      def load_package(action)
        package = Package.find(params[:id])
        authorize_site!(package.site, action)
        package
      end

      def payload(p, full: false)
        h = { "id" => p.id, "site_id" => p.site_id, "key" => p.key, "name" => p.name, "version" => p.version, "source_url" => p.source_url,
              "description" => p.manifest["description"], "items" => p.installed.size, "updated_at" => p.updated_at.iso8601 }
        full ? h.merge("installed" => p.installed, "manifest" => p.manifest) : h
      end
    end
  end
end
