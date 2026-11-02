module Web
  # Dashboards do local (F5). Ver: qualquer papel no local (e na lista
  # `roles` do dashboard, se houver). Editar, publicar e voltar versão:
  # técnico ou dono. O editor mexe só no rascunho; a tela mostra a versão
  # publicada (ou o rascunho, em `?rascunho=1`, para quem edita).
  class DashboardsController < ApplicationController
    UploadError = Class.new(StandardError)
    UPLOAD_TYPES = %w[image/png image/jpeg image/webp].freeze

    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @dashboards = Dashboard.ensure_for(@site).select { |d| d.visible_to?(@site_role) }
    end

    def show
      load_dashboard(:view)
      preview = params[:rascunho].present? && can?(:manage)
      @resolved = Dashboards::Resolver.new(@dashboard, role: @site_role, definition: (@dashboard.working_draft if preview)).call
      @preview = preview
      @view = pick_view(@resolved)
      @dashboards = @site.dashboards.ordered.select { |d| d.visible_to?(@site_role) }
    end

    # Um widget (Turbo Frame): o tempo real e a resposta de um comando recarregam só ele.
    def widget
      load_dashboard(:view)
      resolver = Dashboards::Resolver.new(@dashboard, role: @site_role)
      w = resolver.widget(params[:widget_id]) or raise ActiveRecord::RecordNotFound
      render partial: "web/dashboards/widget", locals: { w: w, points: resolver.points_payload, dashboard: @dashboard, badge: params[:badge].present?, error: flash[:alert] }
    end

    def new
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @dashboard = @site.dashboards.new(kind: "custom")
    end

    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @dashboard = @site.dashboards.new(dashboard_params)
      start = params[:copy_auto] == "1" ? Dashboards::Generator.call(@site) : blank_definition
      @dashboard.definition = start
      return render(:new, status: :unprocessable_content) unless @dashboard.save

      @dashboard.publish!(start)
      redirect_to edit_dashboard_path(@dashboard), notice: "Painel criado. Monte as views e publique."
    end

    def edit
      load_dashboard(:manage)
      @draft = @dashboard.working_draft
      @points = @site.points.includes(:device).order(:name).to_a
      @areas = @site.areas.order(:position, :name).to_a
      @editing = params[:w]
      @live = Dashboards::Resolver.new(@dashboard, role: @site_role, definition: @draft).call # o layout ao vivo
    end

    # Nome, papéis e padrão do local.
    def update
      load_dashboard(:manage)
      @dashboard.assign_attributes(dashboard_params)
      @site.dashboards.where.not(id: @dashboard.id).update_all(site_default: false) if @dashboard.site_default && @dashboard.valid?
      @dashboard.save!
      redirect_to edit_dashboard_path(@dashboard), notice: "Painel salvo."
    end

    def duplicate
      load_dashboard(:manage)
      copy = @dashboard.duplicate!
      redirect_to edit_dashboard_path(copy), notice: "Painel duplicado. Ajuste o nome e as visões."
    end

    def destroy
      load_dashboard(:manage)
      @dashboard.destroy!
      redirect_to settings_dashboards_path, notice: "Painel excluído."
    end

    # Operação do editor no rascunho (ver Dashboards::Editor).
    def draft
      load_dashboard(:manage)
      store_uploads(params)
      editor = Dashboards::Editor.new(@dashboard.working_draft)
      focus = apply(editor)
      save_draft(editor.definition, focus)
    rescue KeyError
      return head(:not_found) if request.format.json?

      redirect_to edit_dashboard_path(@dashboard), alert: "Esse item não existe mais no rascunho."
    rescue UploadError
      redirect_to edit_dashboard_path(@dashboard, view: params[:view_id]), alert: "A imagem precisa ser PNG, JPG ou WebP de até 8 MB."
    end

    def publish
      load_dashboard(:manage)
      @dashboard.publish!(@dashboard.working_draft)
      redirect_to dashboard_path(@dashboard), notice: "Versão #{@dashboard.version} publicada."
    end

    def discard
      load_dashboard(:manage)
      @dashboard.update!(draft: nil)
      redirect_to edit_dashboard_path(@dashboard), notice: "Rascunho descartado."
    end

    def revert
      load_dashboard(:manage)
      @dashboard.revert!(params[:version].to_i)
      redirect_to edit_dashboard_path(@dashboard), notice: "Versão #{params[:version]} publicada de novo como a #{@dashboard.version}."
    end

    def json
      load_dashboard(:manage)
      @text = JSON.pretty_generate(@dashboard.working_draft)
    end

    def update_json
      load_dashboard(:manage)
      @text = params[:definition].to_s
      parsed = JSON.parse(@text)
      @errors = Dashboards::Schema.errors(parsed)
      return render(:json, status: :unprocessable_content) if @errors.any?

      @dashboard.update!(draft: parsed)
      redirect_to edit_dashboard_path(@dashboard), notice: "JSON válido, salvo no rascunho."
    rescue JSON::ParserError => e
      @errors = [ "JSON inválido: #{e.message.truncate(160)}" ]
      render :json, status: :unprocessable_content
    end

    # Painel padrão da pessoa (e o local que abre no Início).
    def prefer
      load_dashboard(:view)
      current_user.update!(dashboard_prefs: current_user.dashboard_prefs.merge("site" => @site.id, @site.id => @dashboard.id))
      redirect_to root_path, notice: "#{@dashboard.name} agora abre no seu Início."
    end

    private

    # Leitor (viewer) vê o painel e o que ele abre; comando e cadastro barram pelo papel.
    def viewer_allowed? = true

    # Arquivo de qualquer campo `upload` do formulário (planta baixa, papel de
    # parede): vira anexo do painel e o campo irmão `image` recebe o link.
    # Genérico: plugin novo com upload não mexe aqui. O tipo vem do conteúdo.
    def store_uploads(node)
      return unless node.is_a?(ActionController::Parameters)

      node.each_value { |v| store_uploads(v) }
      file = node[:upload]
      return unless file.respond_to?(:original_filename)
      type = Marcel::MimeType.for(file.tempfile) # só pelos bytes: o nome e o tipo declarado não valem
      raise UploadError unless file.size <= 8.megabytes && UPLOAD_TYPES.include?(type)

      blob = ActiveStorage::Blob.create_and_upload!(io: file.tempfile, filename: file.original_filename, content_type: type, identify: false)
      @dashboard.files.attach(blob)
      node[:image] = rails_blob_path(blob, only_path: true)
    end

    def load_dashboard(action)
      @dashboard = Dashboard.find(params[:id])
      @site = @dashboard.site
      authorize_site!(@site, action)
      raise ActiveRecord::RecordNotFound unless @dashboard.visible_to?(@site_role)
    end

    def pick_view(resolved)
      Dashboards.pick_view(resolved, params[:view])
    end

    def dashboard_params
      params.require(:dashboard).permit(:name, :kind, :site_default, :icon, :sidebar, roles: []).tap { |p| p[:roles] = Array(p[:roles]).compact_blank if p.key?(:roles) }
    end

    def blank_definition = { "schema_version" => Dashboards::Schema::VERSION, "views" => [ { "id" => "home", "title" => "Início", "sections" => [] } ] }

    # Devolve o widget/view para focar depois de salvar.
    def apply(editor)
      t = params[:target]
      focus = { view: params[:view_id] }
      case params[:op]
      when "add_view" then focus[:view] = editor.add_view(title: params[:title], icon: params[:icon])
      when "update_view" then editor.update_view(t, title: params[:title], icon: params[:icon], path: params[:path])
      when "add_section" then editor.add_section(params[:view_id], title: params[:title])
      when "update_section" then editor.update_section(t, title: params[:title], span: span_param)
      when "add_widget" then focus[:w] = editor.add_widget(t, widget_attrs)
      when "update_widget" then editor.update_widget(t, widget_attrs)
      when "move" then editor.move(params[:kind], t, params[:dir])
      when "place" then editor.place(params[:kind], t, params[:index], parent: params[:parent])
      when "resize" then editor.resize(params[:kind], t, params[:screen].to_s, params[:cols])
      when "remove" then editor.remove(params[:kind], t)
      else raise KeyError, "op"
      end
      focus
    end

    def save_draft(definition, focus)
      errors = Dashboards::Schema.errors(definition)
      if request.format.json? # arrastar e soltar do editor (fetch)
        return render(json: { errors: errors }, status: :unprocessable_content) if errors.any?

        @dashboard.update!(draft: definition)
        return head(:no_content)
      end
      return redirect_to(edit_dashboard_path(@dashboard, view: focus[:view], w: focus[:w]), alert: errors.first(3).to_sentence) if errors.any?

      @dashboard.update!(draft: definition)
      redirect_to edit_dashboard_path(@dashboard, view: focus[:view].presence || params[:view_id], w: focus[:w], anchor: focus[:w]),
                  notice: "Salvo no rascunho. Publique para todos verem."
    end

    # Formulário do widget → JSON (só o que vale para o tipo; vazio some).
    def widget_attrs
      p = params.fetch(:widget, {}).permit(:type, :label, :bind, *Dashboards::Widgets.plugins.flat_map(&:permit).uniq,
                                           binds: [], roles: [], screens: [], query: %i[capability state tag area device_class quality integration unchanged_min exclude sort])
      type = p[:type].presence_in(Dashboards::Schema.types.keys) || "tile"
      attrs = { "type" => type, "label" => p[:label].presence, "span" => span_param }
      attrs.merge!(Dashboards::Widgets[type]&.attrs(p, @site) || {}) # o plugin do tipo diz as props
      roles = Array(p[:roles]).compact_blank
      screens = Array(p[:screens]).compact_blank & Dashboards::Schema::SCREENS
      visible = { "role" => (roles if roles.any? && roles.size < SiteMembership::ROLES.size),
                  "screen" => (screens if screens.any? && screens.size < Dashboards::Schema::SCREENS.size) }.compact
      attrs["visible_if"] = visible.presence
      attrs.compact
    end

    def span_param
      s = params.fetch(:span, {}).permit(*Dashboards::Schema::SCREENS).to_h.transform_values(&:to_i).select { |_, n| n.between?(1, 12) }
      s.presence
    end
  end
end
