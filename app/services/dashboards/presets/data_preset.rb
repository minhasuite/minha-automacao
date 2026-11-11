module Dashboards
  module Presets
    # Predefinição como dado (P2.2): o item `preset` de um pacote ou da
    # biblioteca embutida (ideia 20). Responde como as classes de `Presets`
    # (key, title, icon, description, fields, errors, build), então a tela e a
    # criação não mudam.
    #
    #   { "type": "preset", "key": "cozinha", "name": "Tablet da cozinha", "icon": "home",
    #     "fields": [ { "key": "luz", "label": "Luz da bancada", "kind": "point", "filter": { "capability": "onoff,dimmer" }, "required": true },
    #                 { "key": "area", "label": "Cozinha", "kind": "area" } ],
    #     "definition": { "schema_version": 1, "views": [ ... "bind": "{{ fields.luz }}" ... ] } }
    #
    # `kind`: point, points, area, number, text (os mesmos da classe, mais a
    # área); `default`: o valor quando o campo fica vazio. `filter`: capability (lista com vírgula), device_class, unit,
    # numeric. Montar = trocar os marcadores (`Placeholders`) e validar pelo
    # Schema. Widget cujos campos ficaram todos vazios sai (campo opcional);
    # seção sem widget sai.
    class DataPreset
      KINDS = %w[point points area number text].freeze
      FIELD = CardTemplates::PARAM
      MAX_FIELDS = 30
      SAMPLE = { "point" => "sample", "points" => [ "sample" ], "area" => "sample", "number" => 1, "text" => "x" }.freeze
      Field = Base::Field

      attr_reader :key, :item, :manifest, :source, :package

      def self.from_manifest(manifest, source:, package: nil)
        Array(manifest.to_h["items"]).filter_map do |item|
          new(item, manifest, source: source, package: package) if item.is_a?(Hash) && item["type"] == "preset" && item["key"].is_a?(String)
        end
      end

      def initialize(item, manifest, source:, package: nil)
        @item = item
        @manifest = manifest
        @source = source
        @package = package
        @key = package ? "#{package.key}--#{item['key']}" : item["key"]
      end

      def title = CardTemplates.loc(item["name"]).presence || item["key"]
      def description = CardTemplates.loc(item["description"]).presence || CardTemplates.loc(manifest["description"])
      def icon = item["icon"].presence || "view-boards"
      # De onde veio, para a tela: a biblioteca ou o nome do pacote.
      def origin = package ? package.name : I18n.t("dashboards.presets.library")

      def fields
        Array(item["fields"]).filter_map do |f|
          next unless f.is_a?(Hash) && KINDS.include?(f["kind"])

          Field.new(key: f["key"], label: CardTemplates.loc(f["label"]).presence || f["key"], kind: f["kind"].to_sym,
                    hint: CardTemplates.loc(f["hint"]).presence || (I18n.t("dashboards.presets.optional") unless f["required"]), filter: filter(f["filter"]))
        end
      end

      def required = Array(item["fields"]).select { |f| f.is_a?(Hash) && f["required"] }.map { |f| f["key"] }

      def errors(site, form)
        values = values(site, form)
        missing = required.reject { |k| present?(values[k]) }
        missing.any? ? [ I18n.t("dashboards.presets.required", fields: fields.select { |f| missing.include?(f.key) }.map(&:label).to_sentence) ] : []
      end

      def build(site, form) = self.class.fill(item["definition"].to_h, values(site, form))

      # Biblioteca: os modelos de card do mesmo manifesto entram no local (se ainda não existem).
      def prepare!(site)
        return if package

        Array(manifest["items"]).select { |i| i.is_a?(Hash) && i["type"] == "card_template" }.each do |i|
          next if site.card_templates.exists?(key: i["key"])

          Packages::Items::CardTemplateItem.build(site, i).tap { |t| t.source = "library" }.save!
        end
      end

      # Campos do formulário → valores, só com o que é mesmo do local.
      def values(site, form)
        form = form.to_h.with_indifferent_access
        defaults = Array(item["fields"]).select { |f| f.is_a?(Hash) }.to_h { |f| [ f["key"], f["default"] ] }
        fields.to_h do |f|
          raw = form[f.key].presence || defaults[f.key]
          v = case f.kind
          when :point then Base.pick(site, [ raw ]).first&.id
          when :points then Base.pick(site, raw).first(8).map(&:id)
          when :area then site.areas.find_by(id: raw.presence)&.id
          when :number then Widgets::Base.number(raw)
          else raw.to_s.strip.first(120).presence
          end
          [ f.key, v ]
        end
      end

      # A definição com os valores: widget de campos todos vazios sai; seção vazia sai.
      def self.fill(definition, values)
        views = Array(definition["views"]).map do |v|
          v = v.merge("badges" => prune(v["badges"], values)) if v.key?("badges")
          v.merge("sections" => Array(v["sections"]).filter_map { |s| (w = prune(s["widgets"], values)).any? ? s.merge("widgets" => w) : nil })
        end
        Placeholders.fill(definition.merge("views" => views), "fields") { |path| values[path.split(".").first] }
      end

      def self.prune(widgets, values)
        Array(widgets).filter_map do |w|
          next w unless w.is_a?(Hash)

          used = Placeholders.names(w.except("widgets"), "fields")
          next nil if used.any? && used.none? { |k| !Placeholders.empty?(values[k]) }

          w.key?("widgets") ? w.merge("widgets" => prune(w["widgets"], values)) : w
        end
      end

      # Validação do item (Packages::Items::PresetItem): campos, marcadores e o Schema com valores de exemplo.
      def self.errors(item)
        e = []
        e << I18n.t("packages.errors.name") if CardTemplates.loc(item["name"]).strip.empty?
        list = item["fields"]
        return e << I18n.t("dashboards.presets.errors.fields", max: MAX_FIELDS) unless list.is_a?(Array) && list.size <= MAX_FIELDS

        keys = list.filter_map { |f| f["key"] if f.is_a?(Hash) }
        list.each_with_index do |f, i|
          ok = f.is_a?(Hash) && f["key"].to_s.match?(FIELD) && KINDS.include?(f["kind"]) && keys.count(f["key"]) == 1 && (f["filter"].nil? || f["filter"].is_a?(Hash))
          e << I18n.t("dashboards.presets.errors.field", n: i + 1, kinds: KINDS.join(", ")) unless ok
        end
        return e << I18n.t("dashboards.presets.errors.definition") unless item["definition"].is_a?(Hash)

        unknown = Placeholders.names(item["definition"], "fields") - keys
        e << I18n.t("dashboards.presets.errors.unknown", fields: unknown.join(", ")) if unknown.any?
        sample = list.select { |f| f.is_a?(Hash) }.to_h { |f| [ f["key"], SAMPLE[f["kind"]] ] }
        e + Schema.errors(fill(item["definition"], sample))
      end

      private

      def present?(v) = !Placeholders.empty?(v)

      # Filtro do campo como dado → o lambda que a tela usa para listar os pontos.
      def filter(spec)
        return nil unless spec.is_a?(Hash) && spec.any?

        caps = spec["capability"].to_s.split(",").map(&:strip).compact_blank
        lambda do |p|
          (caps.empty? || caps.include?(p.capability)) && (spec["device_class"].blank? || p.device_class.to_s == spec["device_class"]) &&
            (spec["unit"].blank? || p.unit.to_s == spec["unit"]) && (spec["numeric"] != true || p.numeric?)
        end
      end
    end
  end
end
