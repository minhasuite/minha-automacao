module Api
  module V1
    # Dashboards (F5, ESQUEMA-V1 §6 e §8). Ver: qualquer papel no local (e
    # na lista `roles` do dashboard). Criar, alterar, publicar, voltar versão e
    # excluir: técnico ou dono. `GET /dashboards/:id` devolve a versão
    # publicada resolvida (valores atuais dos pontos, com ETag); `?draft=1`
    # (quem edita) resolve o rascunho. Formato em docs/dashboards.md.
    class DashboardsController < BaseController
      def index
        site = Site.find(params[:site_id])
        role = authorize_site!(site, :view)
        list = Dashboard.ensure_for(site).select { |d| d.visible_to?(role) }
        default = Dashboard.default_for(site, current_user, role)
        render_data(list.map { |d| summary(d).merge(default: d.id == default&.id) })
      end

      def show
        dashboard, role = find(:view)
        draft = bool(params[:draft]) && SiteMembership.allowed?(role, :manage)
        payload = Dashboards::Resolver.new(dashboard, role: role, definition: (dashboard.working_draft if draft)).call
        render_data(payload) if stale?(etag: payload.to_json)
      end

      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        definition = params[:definition].present? ? definition_param : Dashboards::Generator.call(site)
        dashboard = site.dashboards.create!(attrs.merge(definition: definition))
        dashboard.publish!(definition)
        render_data(summary(dashboard), status: :created)
      end

      # PUT/PATCH {name?, kind?, roles?, site_default?, definition?, publish?}:
      # `definition` é validada e publicada como versão nova (com `publish:
      # false`, fica só no rascunho).
      def update
        dashboard, = find(:manage)
        Dashboard.transaction do
          dashboard.update!(attrs)
          dashboard.site.dashboards.where.not(id: dashboard.id).update_all(site_default: false) if dashboard.site_default
          if params.key?(:definition)
            definition = definition_param
            params[:publish] == false || params[:publish] == "false" ? dashboard.update!(draft: definition) : dashboard.publish!(definition)
          end
        end
        render_data(summary(dashboard.reload))
      end

      def publish
        dashboard, = find(:manage)
        dashboard.publish!(dashboard.working_draft)
        render_data(summary(dashboard))
      end

      def revert
        dashboard, = find(:manage)
        dashboard.revert!(params.require(:version).to_i)
        render_data(summary(dashboard))
      end

      # GET /dashboards/:id/definition (técnico ou dono): o rascunho em edição
      # (ou a publicada) e o catálogo de widgets dos plugins, para o editor do app.
      def definition
        dashboard, = find(:manage)
        catalog = Dashboards::Widgets.plugins.map do |p|
          { type: p.type, label: p.label, icon: p.icon, required: p.required, bind: p.bind?, binds: p.binds?, params: p.params }
        end
        render_data({ definition: dashboard.working_draft, has_draft: dashboard.draft?, version: dashboard.version }, meta: { catalog: catalog })
      end

      def versions
        dashboard, = find(:manage)
        render_data(dashboard.versions.includes(:author).map { |v| { version: v.version, author: v.author&.name, created_at: v.created_at, definition: v.definition } })
      end

      def destroy
        dashboard, = find(:manage)
        dashboard.destroy!
        head :no_content
      end

      private

      # Leitor (viewer) vê o painel e o que ele abre; comando e cadastro barram pelo papel.
      def viewer_allowed? = true

      def find(action)
        dashboard = Dashboard.find(params[:id])
        role = authorize_site!(dashboard.site, action)
        raise ActiveRecord::RecordNotFound unless dashboard.visible_to?(role)

        [ dashboard, role ]
      end

      def attrs
        params.permit(:name, :kind, :site_default, roles: []).to_h
      end

      # JSON da definição como veio (sem strong params: é validado pelo Schema).
      def definition_param
        raw = request.request_parameters["definition"]
        errors = Dashboards::Schema.errors(raw)
        raise ActiveRecord::RecordInvalid, Dashboard.new.tap { |d| errors.each { |e| d.errors.add(:definition, e) } } if errors.any?

        raw
      end

      def summary(d)
        { id: d.id, site_id: d.site_id, name: d.name, kind: d.kind, auto: d.auto, site_default: d.site_default, version: d.version,
          has_draft: d.draft?, roles: d.roles, schema_version: d.schema_version, updated_at: d.updated_at }
      end
    end
  end
end
