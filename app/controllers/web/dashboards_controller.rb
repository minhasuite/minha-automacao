module Web
  # Dashboards do local (F5). Ver: qualquer papel no local (e na lista
  # `roles` do dashboard, se houver). Editar, publicar e voltar versão:
  # técnico ou dono. O editor mexe só no rascunho; a tela mostra a versão
  # publicada (ou o rascunho, em `?rascunho=1`, para quem edita).
  class DashboardsController < ApplicationController
    include DashboardEditing

    UploadError = Class.new(StandardError)
    ClipboardEmpty = Class.new(StandardError)
    UPLOAD_TYPES = %w[image/png image/jpeg image/webp].freeze

    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @dashboards = Dashboard.ensure_for(@site).select { |d| d.visible_to?(@site_role) }
    end

    def show
      load_dashboard(:view)
      return render_embed if params[:embed].present? && can?(:manage)

      load_kiosk
      # Ideia 1: modo editar na própria tela (técnico+): o rascunho com arrastar, largura e ajustes na gaveta.
      @edit_here = params[:editar].present? && can?(:manage) && !kiosk
      preview = (params[:rascunho].present? || @edit_here) && can?(:manage)
      @resolved = preview ? Dashboards::Resolver.new(@dashboard, role: @site_role, definition: @dashboard.working_draft).call : Dashboards::Resolver.cached(@dashboard, role: @site_role).deep_dup
      Dashboards::Hero.apply!(@resolved, site: @site, user: current_user, home: false)
      @preview = preview
      @view = pick_view(@resolved)
      @dashboards = @site.dashboards.ordered.select { |d| d.visible_to?(@site_role) }
      return unless @edit_here

      @history = Dashboards::History.state(@dashboard)
      render :edit_here
    end

    # Um widget (Turbo Frame): o tempo real e a resposta de um comando recarregam só ele.
    def widget
      load_dashboard(:view)
      resolver = Dashboards::Resolver.new(@dashboard, role: @site_role)
      w = resolver.widget(params[:widget_id]) or raise ActiveRecord::RecordNotFound
      render partial: "web/dashboards/widget", locals: { w: w, points: resolver.points_payload, dashboard: @dashboard, badge: params[:badge].present?, error: flash[:alert] }
    end

    # Ideia 14: os pontos que entram num número ou item do widget (`?item=` = o id do item do cartão), com
    # o motivo de cada um (qualidade, última leitura, aparelho). O plugin do tipo diz a lista (`drill`).
    def widget_points
      load_dashboard(:view)
      resolver = Dashboards::Resolver.new(@dashboard, role: @site_role)
      w = resolver.widget(params[:widget_id]) or raise ActiveRecord::RecordNotFound
      @drill = Dashboards::Widgets[w["type"]]&.drill(resolver, w, params[:item].to_s) or raise ActiveRecord::RecordNotFound
      @points = @drill["points"].first(Points::Query::MAX)
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
      redirect_to edit_dashboard_path(@dashboard), notice: t("dashboards.flash.created")
    end

    def edit
      load_dashboard(:manage)
      @draft = @dashboard.working_draft
      load_form_options
      @editing = params[:w]
      @clipboard = Dashboards::Clipboard.read(current_user)
      @history = Dashboards::History.state(@dashboard)
      @live = Dashboards::Resolver.new(@dashboard, role: @site_role, definition: @draft).call # o layout ao vivo
    end

    # Nome, papéis e padrão do local.
    def update
      load_dashboard(:manage)
      @dashboard.assign_attributes(dashboard_params)
      @site.dashboards.where.not(id: @dashboard.id).update_all(site_default: false) if @dashboard.site_default && @dashboard.valid?
      @dashboard.save!
      redirect_to edit_dashboard_path(@dashboard), notice: t("dashboards.flash.saved")
    end

    def duplicate
      load_dashboard(:manage)
      copy = @dashboard.duplicate!
      redirect_to edit_dashboard_path(copy), notice: t("dashboards.flash.duplicated")
    end

    def destroy
      load_dashboard(:manage)
      @dashboard.destroy!
      redirect_to settings_dashboards_path, notice: t("dashboards.flash.deleted")
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

      redirect_to editor_path(view: nil), alert: t("dashboards.flash.gone")
    rescue ClipboardEmpty
      redirect_to editor_path, alert: t("dashboards.clip.empty")
    rescue UploadError
      redirect_to edit_dashboard_path(@dashboard, view: params[:view_id]), alert: t("dashboards.flash.bad_image")
    end

    def publish
      load_dashboard(:manage)
      @dashboard.publish!(@dashboard.working_draft)
      redirect_to dashboard_path(@dashboard), notice: t("dashboards.flash.published", n: @dashboard.version)
    end

    def discard
      load_dashboard(:manage)
      store_draft(nil, "discard")
      redirect_to editor_path, notice: t("dashboards.flash.discarded")
    end

    def revert
      load_dashboard(:manage)
      @dashboard.revert!(params[:version].to_i)
      redirect_to edit_dashboard_path(@dashboard), notice: t("dashboards.flash.reverted", from: params[:version], n: @dashboard.version)
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

      store_draft(parsed, "json")
      redirect_to edit_dashboard_path(@dashboard), notice: t("dashboards.flash.json_saved")
    rescue JSON::ParserError => e
      @errors = [ t("dashboards.flash.bad_json", error: e.message.truncate(160)) ]
      render :json, status: :unprocessable_content
    end

    # Ajustes do quiosque deste aparelho (cookie; ver KioskMode).
    def kiosk_settings
      write_kiosk(params.permit(:saver, :idle, :motion, :dim).to_h)
      redirect_back_or_to root_path(quiosque: 1), notice: t("dashboards.flash.kiosk")
    end

    # Painel padrão da pessoa (e o local que abre no Início).
    def prefer
      load_dashboard(:view)
      current_user.update!(dashboard_prefs: current_user.dashboard_prefs.merge("site" => @site.id, @site.id => @dashboard.id))
      redirect_to root_path, notice: t("dashboards.flash.preferred", name: @dashboard.name)
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

    def pick_view(resolved)
      Dashboards.pick_view(resolved, params[:view])
    end

    def dashboard_params
      params.require(:dashboard).permit(:name, :kind, :site_default, :icon, :sidebar, roles: []).tap { |p| p[:roles] = Array(p[:roles]).compact_blank if p.key?(:roles) }
    end

    def blank_definition = { "schema_version" => Dashboards::Schema::VERSION, "views" => [ { "id" => "home", "title" => t("dashboards.gen.home"), "sections" => [] } ] }

    # Devolve o widget/view para focar depois de salvar.
    def apply(editor)
      t = params[:target]
      focus = { view: params[:view_id] }
      case params[:op]
      when "add_view" then focus[:view] = editor.add_view(title: params[:title], icon: params[:icon])
      when "update_view"
        editor.update_view(t, title: params[:title], icon: params[:icon], path: params[:path], type: params[:view_type], subview: params[:subview], back_path: params[:back_path])
        editor.set_hero(t, hero_param) if params.dig(:hero, :present)
      when "add_section" then editor.add_section(params[:view_id], title: params[:title])
      when "update_section" then editor.update_section(t, title: params[:title], span: span_param, position: params[:position])
      when "add_widget" then focus[:w] = editor.add_widget(t, widget_attrs)
      when "update_widget" then editor.update_widget(t, widget_attrs)
      when "move" then editor.move(params[:kind], t, params[:dir])
      when "place" then editor.place(params[:kind], t, params[:index], parent: params[:parent])
      when "theme" then editor.set_theme(t, theme_param)
      when "resize" then editor.resize(params[:kind], t, params[:screen].to_s, params[:cols])
      when "remove" then editor.remove(params[:kind], t)
      # Ideia 7 (atalho, Ctrl+K) e ideia 4 (colar; a área de transferência é da pessoa).
      when "duplicate" then focus[:w] = editor.duplicate(params[:kind].presence_in(%w[widget section]) || "widget", t)
      when "paste" then focus[:w] = paste(editor, t)
      when "paste_style" then editor.paste_style(t, clip!("widget")["item"])
      else raise KeyError, "op"
      end
      focus
    end

    # Colar o que está na área de transferência: widget numa seção/pilha, seção numa visão.
    def paste(editor, target)
      clip = clip!
      id = editor.paste(clip["kind"], target, clip["item"])
      id if clip["kind"] == "widget"
    end

    def clip!(kind = nil)
      clip = Dashboards::Clipboard.read(current_user)
      raise ClipboardEmpty unless clip && (kind.nil? || clip["kind"] == kind)

      clip
    end

    def save_draft(definition, focus)
      errors = Dashboards::Schema.errors(definition)
      if request.format.json? # arrastar e soltar do editor (fetch)
        return render(json: { errors: errors }, status: :unprocessable_content) if errors.any?

        store_draft(definition, params[:op])
        return head(:no_content)
      end
      return redirect_to(editor_path(view: focus[:view], w: focus[:w]), alert: errors.first(3).to_sentence) if errors.any?

      store_draft(definition, params[:op])
      redirect_to editor_path(view: focus[:view].presence || params[:view_id], w: focus[:w], anchor: focus[:w]), notice: t("dashboards.flash.draft_saved")
    end

    # Ideia 24: o painel dentro da prévia (iframe da revisão), sem moldura, no tema pedido.
    def render_embed
      @resolved = Dashboards::Resolver.new(@dashboard, role: @site_role, definition: @dashboard.working_draft).call
      Dashboards::Hero.apply!(@resolved, site: @site, user: current_user, home: false)
      @preview = true
      @embed = true
      @view = pick_view(@resolved)
      @dashboards = []
      render :show, layout: "embed"
    end

    # Formulário do widget → JSON (só o que vale para o tipo; vazio some).
    def widget_attrs
      p = params.fetch(:widget, {}).permit(:type, :label, :bind, :stale_after_min, *Dashboards::Widgets.plugins.flat_map(&:permit).uniq,
                                           binds: [], roles: [], screens: [], query: Dashboards::Widgets::QueryListWidget::FORM_QUERY)
      type = p[:type].presence_in(Dashboards::Schema.types.keys) || "tile"
      attrs = { "type" => type, "label" => p[:label].presence, "span" => span_param }
      attrs.merge!(Dashboards::Widgets[type]&.attrs(p, @site) || {}) # o plugin do tipo diz as props
      if Dashboards::Widgets[type]&.gestures? # ondaB2: toque, segurar e duplo toque
        attrs.merge!(Dashboards::Actions.from_form(params.fetch(:gestures, {}).permit(Dashboards::Actions::GESTURES.keys.index_with { Dashboards::Actions::FORM }).to_h))
      end
      # P1.2 e ideia 22: estilo condicional e limite do "dado velho" (de qualquer tipo).
      attrs["style_if"] = Dashboards::Style.from_form(form_rows(:style, Dashboards::Style::FORM_FIELDS))
      attrs["stale_after_min"] = p[:stale_after_min].to_i.clamp(0, Dashboards::Staleness::MAX_MIN) if p[:stale_after_min].present?
      roles = Array(p[:roles]).compact_blank
      screens = Array(p[:screens]).compact_blank & Dashboards::Schema::SCREENS
      visible = { "role" => (roles if roles.any? && roles.size < SiteMembership::ROLES.size),
                  "screen" => (screens if screens.any? && screens.size < Dashboards::Schema::SCREENS.size) }.compact
      attrs["visible_if"] = visible.presence
      attrs.compact
    end

    # P1.4: topo da visão pelo formulário → `hero` (vazio some).
    def hero_param
      p = params.fetch(:hero, {}).permit(:title, :kicker, :greeting, :hide)
      { "title" => p[:title].to_s.strip.presence, "kicker" => p[:kicker].to_s.strip.presence,
        "greeting" => { "1" => true, "0" => false }[p[:greeting]], "hide" => (true if p[:hide] == "1") }.compact
    end

    # Tema (uiweb): galeria do editor → JSON; o upload já virou `image` (store_uploads).
    def theme_param
      p = params.fetch(:theme, {}).permit(:key, :night, :image, :blur, :glass, :dark, :remove_image)
      { "key" => p[:key].presence, "night" => p[:night].presence, "image" => (p[:image].presence unless p[:remove_image] == "1"),
        "blur" => (p[:blur].to_i.clamp(0, 40) if p[:blur].present?), "glass" => ({ "1" => true, "0" => false }[p[:glass]]),
        "dark" => (true if p[:dark] == "1") }
    end

    def span_param
      s = params.fetch(:span, {}).permit(*Dashboards::Schema::SCREENS).to_h.transform_values(&:to_i).select { |_, n| n.between?(1, 12) }
      s.presence
    end
  end
end
