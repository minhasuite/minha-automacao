module Dashboards
  # Exportar como pacote (P2.3 da proposta de personalização): um painel ou um
  # modelo de card vira o manifesto de `Packages` (o mesmo que a loja instala).
  # Os pontos e as áreas fixos do local viram **entradas**, como no blueprint:
  #
  # - painel → item `preset` (P2.2): `fields` (um por ponto/área usado) e a
  #   definição com `{{ fields.<entrada> }}`; os modelos do local que ele usa vão
  #   junto como itens `card_template`. Quem importa escolhe os próprios pontos
  #   em Painéis prontos.
  # - modelo → item `card_template`: o ponto/área fixo nos espaços vira uma
  #   entrada nova do modelo (`params`), preenchida no widget (`vars`).
  #
  # Ponto citado pela chave dentro de texto Liquid (`points["sala.luz"]`) fica
  # como está (é texto, não id).
  module Export
    module_function

    def manifest(key, name, description, items)
      { "format" => Packages::FORMAT, "key" => key, "name" => name.to_s.first(120), "version" => "1.0.0",
        "description" => description.to_s.first(300).presence, "items" => items }.compact
    end

    def slug(text, fallback) = text.to_s.parameterize.first(50).presence&.then { |s| s.match?(Packages::KEY) ? s : nil } || fallback

    def dashboard(dashboard)
      site = dashboard.site
      definition = dashboard.published.deep_dup
      refs = Refs.new(site)
      body = refs.swap(definition, "fields")
      used = Resolver.flatten(Array(definition["views"]).flat_map { |v| [ *Array(v["badges"]), *Array(v["sections"]).flat_map { |s| Array(s["widgets"]) } ] })
                     .filter_map { |w| w["template"] if w["type"] == "template" }.uniq
      templates = used.filter_map { |k| site.card_templates.find_by(key: k)&.to_template }.map { |t| template_item(site, t) }
      key = slug(dashboard.name, "painel")
      preset = { "type" => "preset", "key" => key, "name" => dashboard.name, "icon" => dashboard.icon.presence,
                 "fields" => refs.fields, "definition" => body }.compact
      manifest(key, dashboard.name, I18n.t("dashboards.export.description", name: dashboard.name), templates + [ preset ])
    end

    def template(site, t)
      item = template_item(site, t)
      manifest(slug(t["key"], "modelo"), CardTemplates.name(t), CardTemplates.loc(t["description"]), [ item ])
    end

    # O modelo como item de pacote; ponto/área fixo nos espaços → entrada nova.
    def template_item(site, t)
      refs = Refs.new(site, taken: Array(t["params"]).map { |p| p["key"] })
      slots = refs.swap(t["slots"].to_h, "vars")
      params = Array(t["params"]).map { |p| p.merge("label" => CardTemplates.param_label(p)) } +
               refs.fields.map { |f| { "key" => f["key"], "label" => f["label"], "kind" => f["kind"], "required" => true } }
      { "type" => "card_template", "key" => t["key"], "name" => CardTemplates.name(t), "description" => CardTemplates.loc(t["description"]).presence,
        "layout" => t["layout"], "params" => params, "slots" => slots }.compact
    end

    # Troca id de ponto/área do local por `{{ <ns>.<entrada> }}` e anota as entradas.
    class Refs
      attr_reader :fields

      def initialize(site, taken: [])
        @points = site.points.includes(:device).index_by(&:id)
        @areas = site.areas.index_by(&:id)
        @by_id = {}
        @fields = []
        @taken = taken.dup
      end

      def swap(obj, ns)
        case obj
        when Hash then obj.transform_values { |v| swap(v, ns) }
        when Array then obj.map { |v| swap(v, ns) }
        when String then (key = entry(obj)) ? "{{ #{ns}.#{key} }}" : obj
        else obj
        end
      end

      private

      def entry(id)
        return @by_id[id] if @by_id.key?(id)

        if (p = @points[id])
          add(id, p.key.to_s.tr(".-", "__"), p.name, "point", { "capability" => p.capability })
        elsif (a = @areas[id])
          add(id, "area_#{a.name.parameterize(separator: '_')}", a.name, "area", nil)
        end
      end

      def add(id, base, label, kind, filter)
        base = base.gsub(/[^a-z0-9_]/, "").sub(/\A[^a-z]+/, "").first(26).presence || kind
        key = base
        n = 1
        key = "#{base}_#{n += 1}" while @taken.include?(key)
        @taken << key
        @fields << { "key" => key, "label" => label.to_s.first(60), "kind" => kind, "filter" => filter }.compact
        @by_id[id] = key
      end
    end
  end
end
