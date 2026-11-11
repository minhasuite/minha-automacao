module Web
  # Modelos de card do local (P1.3): lista (os do local e os embutidos),
  # duplicar (o cartão de área embutido vira um modelo editável), editor com
  # prévia ao vivo e exportar como pacote (P2.3). Técnico ou dono.
  #
  # Prévia ao vivo: o formulário do editor manda, por padrão, para `preview`
  # (o `ss-autosubmit` da gem envia a cada mudança e a resposta troca só o
  # quadro da prévia); o botão Salvar troca o destino (`formaction`) para
  # criar/atualizar. Nada é gravado na prévia.
  class CardTemplatesController < ApplicationController
    before_action :load_site, only: %i[index new create preview duplicate export]
    before_action :load_template, only: %i[edit update destroy]

    def index
      @templates = Dashboards::CardTemplates.all(@site)
    end

    def new
      @template = @site.card_templates.new(layout: "mosaic", slots: { "title" => "{{ vars.area.name }}" },
                                           params: [ { "key" => "area", "label" => t("dashboards.templates.kinds.area"), "kind" => "area", "required" => true } ])
      first_preview
    end

    def create
      @template = @site.card_templates.new(form_attrs)
      @sample = sample
      @errors = []
      return render(:new, status: :unprocessable_content) unless save_template

      redirect_to edit_card_template_path(@template), notice: t("dashboards.templates.flash.saved", name: @template.name)
    end

    def edit
      first_preview
    end

    def update
      @template.assign_attributes(form_attrs.except(:key))
      @sample = sample
      return render(:edit, status: :unprocessable_content) unless save_template

      redirect_to edit_card_template_path(@template), notice: t("dashboards.templates.flash.saved", name: @template.name)
    end

    def destroy
      @template.destroy!
      redirect_to site_card_templates_path(@site), notice: t("dashboards.templates.flash.removed", name: @template.name)
    end

    # O cartão de área (ou qualquer modelo) como ponto de partida editável.
    def duplicate
      template = Dashboards::CardTemplates.find(@site, params[:key]) or raise ActiveRecord::RecordNotFound
      copy = CardTemplate.duplicate!(@site, template)
      redirect_to edit_card_template_path(copy), notice: t("dashboards.templates.flash.duplicated", name: copy.name)
    end

    # Prévia ao vivo: o modelo do formulário resolvido agora, com as entradas de exemplo.
    def preview
      record = @site.card_templates.new(form_attrs)
      template = record.to_template.merge("key" => record.key.presence || "preview")
      @errors = json_errors + Dashboards::CardTemplates.errors(template)
      @widget = preview_widget(template) if @errors.empty?
      render partial: "web/card_templates/preview", locals: { widget: @widget, errors: @errors, points: @points || {}, dashboard: @dashboard }
    end

    # P2.3: o modelo como pacote (manifesto), com os pontos e as áreas fixos virando entradas.
    def export
      template = Dashboards::CardTemplates.find(@site, params[:key]) or raise ActiveRecord::RecordNotFound
      manifest = Dashboards::Export.template(@site, template)
      send_data JSON.pretty_generate(manifest), filename: "#{manifest['key']}.json", type: :json
    end

    private

    def load_site
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
    end

    def load_template
      @template = CardTemplate.find(params[:id])
      @site = @template.site
      authorize_site!(@site, :manage)
    end

    # Valida o modelo e o JSON dos espaços (texto que começa com { ou [ e não é JSON).
    def save_template
      ok = @template.valid?
      json_errors.each { |m| @template.errors.add(:base, m) }
      ok && json_errors.empty? && @template.save
    end

    def json_errors = (@bad_json || []).map { |slot| t("dashboards.templates.errors.json", slot: slot) }

    def form
      params.fetch(:card_template, {}).permit(:name, :key, :description, :layout, *Dashboards::CardTemplates::SLOTS.map { |s| :"slot_#{s}" },
                                              params: %i[key label kind required remove], sample: {})
    end

    def form_attrs
      f = form
      slots = Dashboards::CardTemplates::SLOTS.each_with_object({}) do |s, h|
        v = slot_value(f[:"slot_#{s}"], s)
        h[s] = v unless v.nil?
      end
      rows = f[:params].respond_to?(:values) ? f[:params].values : Array(f[:params])
      params_list = rows.filter_map do |row|
        next if row[:remove] == "1" || row[:key].blank?

        { "key" => row[:key].to_s.strip.downcase, "label" => row[:label].to_s.strip.presence || row[:key].to_s,
          "kind" => row[:kind].presence_in(Dashboards::CardTemplates::KINDS) || "text", "required" => row[:required] == "1" }
      end
      { name: f[:name].to_s.strip.first(80), key: f[:key].to_s.strip.downcase.presence, description: f[:description].to_s.strip.first(200).presence,
        layout: f[:layout], slots: slots, params: params_list }.compact
    end

    # Texto do campo → espaço: começa com { (não {{ nem {%) ou [ = JSON (consulta, regras, itens, ação); senão, texto (Liquid).
    def slot_value(text, slot)
      text = text.to_s.strip
      return nil if text.empty?
      return text unless text.start_with?("[") || (text.start_with?("{") && !text.start_with?("{{", "{%"))

      JSON.parse(text)
    rescue JSON::ParserError
      (@bad_json ||= []) << slot
      nil
    end

    def sample = form[:sample].to_h.transform_values(&:to_s).compact_blank

    # Prévia de abertura: a primeira área e o primeiro ponto do local como exemplo.
    def first_preview
      tpl = @template.to_template.merge("key" => @template.key.presence || "preview")
      @sample = Array(tpl["params"]).each_with_object({}) do |p, h|
        v = { "area" => -> { @site.areas.order(:position, :name).pick(:id) }, "point" => -> { @site.points.where(disabled: false).ordered.pick(:id) } }[p["kind"]]&.call
        h[p["key"]] = v if v
      end
      @errors = Dashboards::CardTemplates.errors(tpl)
      @widget = preview_widget(tpl) if @errors.empty?
    end

    # Um widget resolvido como o painel resolveria, num painel de mentira (não gravado).
    def preview_widget(template)
      @dashboard = @site.dashboards.new(kind: "custom", name: "preview")
      r = Dashboards::Resolver.new(@dashboard, role: @site_role, definition: { "views" => [] })
      w = { "id" => "tpl-preview", "type" => "template", "template" => template["key"], "vars" => sample }
      data, deps = Dashboards::CardTemplates.render(r, template, sample, widget: nil)
      @points = r.points_payload
      w.merge("visible" => true, "data" => data.except("tap"), "deps" => deps.map(&:id))
    end
  end
end
