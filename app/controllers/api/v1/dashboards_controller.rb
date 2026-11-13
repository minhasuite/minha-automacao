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
        device = PanelDevice.current(request) # ideia 10: o id do app em X-MA-Device
        device&.seen!(request.user_agent)
        mine = device&.dashboard_for(site, role)
        default = mine || Dashboard.default_for(site, current_user, role, app: true) # a API é a do app
        render_data(list.map { |d| summary(d).merge(default: d.id == default&.id, device_default: d.id == mine&.id) })
      end

      def show
        dashboard, role = find(:view)
        draft = bool(params[:draft]) && SiteMembership.allowed?(role, :manage)
        device = PanelDevice.current(request) # ideia 10: a visão deste aparelho vence o `open_if`
        device_view = device.view if device&.dashboard_id == dashboard.id && device.view.present?
        # `?lazy=1` (app novo): só uma visão resolvida (`view`, ou a que abre); as outras com `lazy: true`,
        # pedidas com `?lazy=1&view=<id>` ao trocar de aba. Sem `lazy`, todas (app antigo).
        lazy = bool(params[:lazy])
        payload = if draft
          Dashboards::Resolver.new(dashboard, role: role, definition: dashboard.working_draft, only_view: (params[:view].presence || device_view || :open if lazy)).call
        else
          Dashboards::Resolver.cached(dashboard, role: role, view: params[:view].presence || device_view, lazy: lazy).deep_dup
        end
        Dashboards::Hero.apply!(payload, site: dashboard.site, user: current_user) # P1.4: o topo pronto (o app é o Início)
        Dashboards::Personal.apply!(payload, site: dashboard.site, user: current_user, role: role) # ideia 13: busca e favoritos
        payload["open_view"] = device_view if device_view
        render_data(payload) if stale?(etag: payload.to_json)
      end

      # Quiosque do app (ideia 21): as fotos do protetor de tela (o álbum; sem álbum, as imagens
      # do painel), como caminhos do próprio servidor (o app junta com o endereço dele).
      def album
        dashboard, = find(:view)
        render_data(dashboard.saver_photos.map { |f| { id: f.id, url: rails_blob_path(f, only_path: true) } })
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

      # POST /dashboards/:id/widgets/:widget_id/batch {slot}: ação em lote (ideia 12). → {sent, skipped, failed}.
      def batch
        dashboard, role = find(:view)
        resolver = Dashboards::Resolver.new(dashboard, role: role)
        w = resolver.widget(params[:widget_id]) or raise ActiveRecord::RecordNotFound
        action = Dashboards::Batch.action_for(w, params[:slot].to_s, site: dashboard.site) or raise ActiveRecord::RecordNotFound
        result = Dashboards::Batch.run(resolver, action, source: "api")
        render_data(result.to_h.merge("message" => Dashboards::Batch.message(result)))
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
        { id: d.id, site_id: d.site_id, name: d.name, kind: d.kind, auto: d.auto, site_default: d.site_default, app_default: d.app_default, icon: d.icon, version: d.version,
          has_draft: d.draft?, roles: d.roles, schema_version: d.schema_version, updated_at: d.updated_at }
      end
    end
  end
end
