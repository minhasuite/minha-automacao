module Dashboards
  # Montagem por frase (ideia 3 da proposta de personalização): "monte a visão
  # do escritório com luzes, ar e câmera" → a IA DA INSTALAÇÃO (`Ai::Request`,
  # chave do usuário; nunca IA da suíte) devolve uma visão em formato curto
  # (seções com {tipo, ponto, nome}); aqui ela vira widgets de verdade, só com
  # pontos do local e tipos de widget de um ponto (`Widgets`), cada um
  # conferido pelo `Schema` (o que não passa cai no widget do aparelho ou no
  # `tile`, ou sai). O resultado entra no RASCUNHO (substitui a visão de mesmo
  # nome ou entra no fim); o dono vê o antes → depois e publica. A IA não
  # comanda nada nem vê nada além da lista de pontos.
  class Compose
    class Error < StandardError; end

    MAX_POINTS = 400
    MAX_TEXT = 500
    MAX_SECTIONS = 8
    MAX_WIDGETS = 40
    SYSTEM = "Você monta visões de painel de automação residencial. Use só os pontos da lista (pelo id exato) e só os tipos de " \
             "widget da lista. Agrupe em seções curtas com título. Responda só com o JSON pedido, títulos no idioma: %{lang}.".freeze
    LANGUAGES = { "pt-BR" => "português do Brasil", "en" => "inglês", "es" => "espanhol" }.freeze

    Result = Data.define(:definition, :view_id, :dropped)

    def self.call(...) = new(...).call

    def initialize(dashboard, text, user: nil)
      @dashboard = dashboard
      @site = dashboard.site
      @text = text.to_s.squish.first(MAX_TEXT)
      @user = user
    end

    def call
      raise Error, I18n.t("arrange.compose.empty") if @text.blank?

      points = @site.points.includes(:device).order(:name).to_a.select { |p| Points::Query.exists?(p) }.first(MAX_POINTS)
      raise Error, I18n.t("arrange.compose.no_points") if points.empty?

      @by_id = points.index_by(&:id)
      data = ask(points)
      view, dropped = build(data)
      raise Error, I18n.t("arrange.compose.nothing") if view["sections"].sum { _1["widgets"].size }.zero?

      defn = place(@dashboard.working_draft.deep_dup, view)
      errors = Schema.errors(defn)
      raise Error, errors.first(3).to_sentence if errors.any?

      Result.new(definition: defn, view_id: view["id"], dropped: dropped)
    end

    # Tipos de widget de um ponto só (o plugin diz: `bind` e nada mais obrigatório).
    def self.types = Widgets.plugins.select { |p| p.bind? && (p.required - %w[bind]).empty? }

    private

    def structured?
      AiAccount.pick(nil, default: Ai::Budget.for(@site.tenant).default_provider)&.plugin&.supports?(:structured)
    end

    def ask(points)
      types = self.class.types
      schema = { type: "object", required: %w[title sections], properties: {
        title: { type: "string" }, icon: { type: "string" },
        sections: { type: "array", items: { type: "object", required: %w[title widgets], properties: {
          title: { type: "string" },
          widgets: { type: "array", items: { type: "object", required: %w[type point], properties: {
            type: { type: "string", enum: types.map(&:type) }, point: { type: "string" }, label: { type: "string" }
          } } }
        } } }
      } }
      areas = @site.areas.pluck(:id, :name).to_h
      lines = points.map do |p|
        [ p.id, p.name, p.device&.name, areas[p.effective_area_id], p.capability, p.device_class, p.unit, p.writable ? "comanda" : "leitura" ].map(&:to_s).join(" | ")
      end
      prompt = [ "Pedido: #{@text}", "", "Tipos de widget (tipo: nome):", *types.map { |t| "#{t.type}: #{t.label}" }, "",
                 "Pontos (id | nome | aparelho | área | capacidade | classe | unidade | comanda/leitura):", *lines ]
      structured = structured?
      prompt += [ "", "Formato: #{schema.to_json}" ] unless structured
      res = Ai::Request.call(tenant: @site.tenant, site: @site, source: "painel", prompt: prompt.join("\n"), max_tokens: 2_000, timeout: 60,
                             system: format(SYSTEM, lang: LANGUAGES.fetch(I18n.locale.to_s, LANGUAGES["pt-BR"])), schema: (schema if structured))
      parse(res.data)
    rescue Ai::Client::Error => e
      raise Error, e.message
    end

    def parse(data)
      return data.deep_stringify_keys if data.is_a?(Hash)

      text = data.to_s
      json = text[text.index("{")..text.rindex("}")] if text.include?("{") && text.include?("}")
      JSON.parse(json.to_s).then { |h| h.is_a?(Hash) ? h : raise(JSON::ParserError) }
    rescue JSON::ParserError
      raise Error, I18n.t("arrange.compose.bad_answer")
    end

    def build(data)
      title = data["title"].to_s.squish.first(60).presence || @text.first(60)
      dropped = []
      n = 0
      sections = Array(data["sections"]).select { _1.is_a?(Hash) }.first(MAX_SECTIONS).each_with_index.map do |s, si|
        widgets = Array(s["widgets"]).select { _1.is_a?(Hash) }.filter_map do |w|
          p = @by_id[w["point"].to_s]
          dropped << w["point"].to_s.first(40) unless p
          next if p.nil? || (n += 1) > MAX_WIDGETS

          widget(w, p, "ia-w#{n}").tap { |x| dropped << p.name unless x }
        end
        { "id" => "ia-s#{si + 1}", "title" => s["title"].to_s.squish.first(60).presence, "widgets" => widgets }.compact
      end
      sections = sections.reject { _1["widgets"].empty? }
      area = @site.areas.to_a.find { |a| a.name.casecmp?(title) }
      icon = data["icon"].to_s.presence_in(Dashboard::ICONS) || area&.icon.presence || "view-boards"
      [ { "id" => "ia-view", "title" => title, "icon" => icon, "area" => area&.id, "sections" => sections }.compact, dropped.uniq ]
    end

    # O tipo pedido; senão o widget do aparelho (câmera, robô...); senão `tile`. Só o que o Schema aceita.
    def widget(w, point, id)
      label = w["label"].to_s.squish.first(60).presence
      asked = (plugin = self.class.types.find { _1.type == w["type"] }) && { "id" => id, "type" => plugin.type, "bind" => point.id }
      [ asked, Widgets.auto_widget(point, id), { "id" => id, "type" => "tile", "bind" => point.id } ].compact.each do |cand|
        cand = cand.merge("label" => label).compact if label && label != point.name
        return cand if valid?(cand)
      end
      nil
    end

    def valid?(w)
      Schema.errors({ "schema_version" => Schema::VERSION, "views" => [ { "id" => "v", "title" => "v", "sections" => [ { "id" => "s", "widgets" => [ w ] } ] } ] }).empty?
    end

    # Substitui a visão de mesmo nome (mantém id, caminho e tema) ou entra no fim; ids únicos no painel.
    def place(defn, view)
      views = Array(defn["views"])
      old = views.find { |v| v["title"].to_s.casecmp?(view["title"]) }
      vid = old ? old["id"] : unique("ia-#{view['title'].parameterize.first(30).presence || 'visao'}", views.pluck("id"))
      taken = views.reject { _1.equal?(old) }.flat_map { |v| [ v["id"], *Array(v["badges"]).pluck("id"), *Array(v["sections"]).flat_map { |s| [ s["id"], *Resolver.flatten(Array(s["widgets"])).pluck("id") ] } ] }
      view = view.merge("id" => vid, "sections" => view["sections"].map do |s|
        s.merge("id" => unique("#{vid}-#{s['id']}", taken), "widgets" => s["widgets"].map { |w| w.merge("id" => unique("#{vid}-#{w['id']}", taken)) })
      end)
      view = old.slice("path", "theme", "hero", "subview", "back_path").merge(view) if old
      defn.merge("views" => old ? views.map { |v| v.equal?(old) ? view : v } : views + [ view ])
    end

    def unique(base, taken)
      id = base
      n = 1
      id = "#{base}-#{n += 1}" while taken.include?(id)
      taken << id
      id
    end
  end
end
