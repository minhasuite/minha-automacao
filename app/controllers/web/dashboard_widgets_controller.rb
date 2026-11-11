module Web
  # Um widget no editor de painel (técnico ou dono): o JSON só dele (P1.5,
  # validado pelo Dashboards::Schema, que chama Facts/Style/Hero e o plugin),
  # o formulário na gaveta da edição na própria tela (ideia 1) e o copiar para
  # a área de transferência da pessoa (ideia 4; o colar é op do rascunho).
  class DashboardWidgetsController < ApplicationController
    include DashboardEditing

    def json
      load_widget
      @text = JSON.pretty_generate(@widget.except("id"))
    end

    def update_json
      load_widget
      @text = params[:widget_json].to_s
      parsed = JSON.parse(@text)
      editor = Dashboards::Editor.new(@dashboard.working_draft)
      editor.replace_widget(@widget["id"], parsed)
      @errors = Dashboards::Schema.errors(editor.definition)
      return render(:json, status: :unprocessable_content) if @errors.any?

      store_draft(editor.definition, "widget_json")
      redirect_to editor_path(view: @view_id, w: @widget["id"], anchor: @widget["id"]), notice: t("dashboards.flash.json_saved")
    rescue JSON::ParserError, ArgumentError => e
      @errors = [ e.is_a?(JSON::ParserError) ? t("dashboards.flash.bad_json", error: e.message.truncate(160)) : t("dashboards.wjson.object") ]
      render :json, status: :unprocessable_content
    end

    # Ideia 1: os ajustes do widget na gaveta (frame `dw-drawer`).
    def form
      load_widget
      load_form_options
      @clipboard = Dashboards::Clipboard.read(current_user)
      render layout: false
    end

    def copy
      load_dashboard(:manage)
      kind = params[:kind].presence_in(Dashboards::Clipboard::KINDS) or raise ActiveRecord::RecordNotFound
      item = Dashboards::Editor.new(@dashboard.working_draft).item(kind, params[:target].to_s)
      label = Dashboards::Diff.label(item, @site.points.where(id: item["bind"].to_s).pluck(:id, :name).to_h)
      return redirect_to(editor_path, alert: t("dashboards.clip.too_big")) unless Dashboards::Clipboard.copy!(current_user, kind, item, label: label)

      redirect_to editor_path(w: (params[:target] if kind == "widget")), notice: t("dashboards.clip.copied_#{kind}", name: label)
    rescue KeyError
      redirect_to editor_path, alert: t("dashboards.flash.gone")
    end

    private

    def load_widget
      load_dashboard(:manage)
      @draft = @dashboard.working_draft
      editor = Dashboards::Editor.new(@draft)
      @widget = editor.widget(params[:widget_id].to_s)
      @view_id = Array(@draft["views"]).find { |v| v.to_json.include?(%("id":#{@widget['id'].to_json})) }&.dig("id")
      @schema = Dashboards::JsonSchema.for_type(@widget["type"])
      @names = @site.points.where(id: @widget["bind"].to_s).pluck(:id, :name).to_h
    rescue KeyError
      raise ActiveRecord::RecordNotFound
    end
  end
end
