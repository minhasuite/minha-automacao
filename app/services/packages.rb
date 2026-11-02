# Loja de pacotes (Pacote 3; o HACS do HA, só declarativo). Um pacote é um
# manifesto versionado (JSON ou YAML) num repositório git ou numa URL, com
# itens que entram nos registros que já existem: mapas de dados de aparelho,
# blueprints, modelos de painel e helpers. **Nunca código** (Ruby, JS,
# shell): só há os tipos de item de `ITEMS`, cada um vira registro validado
# pelo próprio registro, e nada do pacote é executado.
#
# Formato (docs/pacotes.md):
#   { "format": 1, "key": "luzes-basicas", "name": "...", "version": "1.2.0",
#     "description": "...", "items": [ { "type": "blueprint", "key": "...", ... } ] }
#
# Fonte nova (outro host de git) = classe em Packages::Sources + nome em
# `SOURCES`; tipo de item novo = classe em Packages::Items + nome em `ITEMS`.
module Packages
  class Error < StandardError; end

  FORMAT = 1
  MAX_BYTES = 512 * 1024
  MAX_ITEMS = 100
  KEY = /\A[a-z0-9][a-z0-9_-]{1,59}\z/
  VERSION = /\A\d+(\.\d+){0,3}([-+.][0-9A-Za-z.]+)?\z/
  FILES = %w[minha-automacao.json minha-automacao.yml minha-automacao.yaml].freeze
  SOURCES = %w[GithubRepo GitlabRepo ManifestUrl].freeze
  ITEMS = %w[DeviceMapItem BlueprintItem DashboardItem HelperItem CardItem].freeze

  module_function

  def sources = SOURCES.map { |n| Sources.const_get(n) }
  def items = ITEMS.map { |n| Items.const_get(n) }
  def item_type(key) = items.find { |i| i.key == key.to_s }

  # URL do repositório ou do manifesto → [manifesto, url de onde veio].
  def fetch(url)
    url = url.to_s.strip
    source = sources.find { |s| s.match?(url) } or raise Error, I18n.t("packages.errors.url")
    last = nil
    source.candidates(url).each do |candidate|
      res = SafeHttp.get(candidate, timeout: 15)
      next last = I18n.t("packages.errors.status", url: candidate, status: res.status) if res.status == 404
      raise Error, "#{I18n.t('packages.errors.status', url: candidate, status: res.status)}." if res.status >= 400
      raise Error, I18n.t("packages.errors.too_big") if res.body.bytesize > MAX_BYTES

      return [ parse(res.body, candidate), candidate ]
    end
    raise Error, "#{I18n.t('packages.errors.not_found', files: FILES.join(', '))} #{last}".strip
  rescue SafeHttp::Error => e
    raise Error, I18n.t("packages.errors.download", error: e.message)
  end

  def parse(body, name = "")
    data = name.to_s.match?(/\.ya?ml\z/) ? YAML.safe_load(body, permitted_classes: [], aliases: false) : JSON.parse(body)
    raise Error, I18n.t("packages.errors.object") unless data.is_a?(Hash)

    data
  rescue JSON::ParserError, Psych::Exception => e
    raise Error, I18n.t("packages.errors.invalid", error: e.message.truncate(120))
  end

  # Erros do manifesto (vazio = válido). Cada item é validado pelo tipo dele.
  def errors(manifest, site)
    m = manifest.to_h
    list = []
    list << I18n.t("packages.errors.format", expected: FORMAT) unless m["format"] == FORMAT
    list << I18n.t("packages.errors.key") unless m["key"].is_a?(String) && KEY.match?(m["key"])
    list << I18n.t("packages.errors.name") unless m["name"].is_a?(String) && m["name"].strip.present?
    list << I18n.t("packages.errors.version") unless m["version"].is_a?(String) && VERSION.match?(m["version"])
    items = m["items"]
    return list << I18n.t("packages.errors.items", max: MAX_ITEMS) unless items.is_a?(Array) && items.size.between?(1, MAX_ITEMS)

    keys = []
    items.each_with_index do |item, i|
      where = "item #{i + 1}"
      next list << "#{where}: #{I18n.t('packages.errors.item_object')}" unless item.is_a?(Hash)

      type = item_type(item["type"])
      next list << "#{where}: #{I18n.t('packages.errors.type', type: item['type'], types: ITEMS.map { |n| Items.const_get(n).key }.join(', '))}" unless type
      next list << "#{where}: #{I18n.t('packages.errors.item_key')}" unless item["key"].is_a?(String) && KEY.match?(item["key"])

      list << "#{where}: #{I18n.t('packages.errors.repeated', key: item['key'])}" if keys.include?([ type.key, item["key"] ])
      keys << [ type.key, item["key"] ]
      list.concat(type.errors(site, item).map { |e| "#{where} (#{item['key']}): #{e}" })
    end
    list
  end

  # O que entra, muda ou sai se instalar/atualizar este manifesto.
  def preview(site, manifest, package = nil)
    items = Array(manifest["items"]).select { |i| i.is_a?(Hash) && item_type(i["type"]) }
    plan = items.map do |item|
      type = item_type(item["type"])
      exists = package&.ref(type.key, item["key"])
      { "type" => type.key, "type_label" => type.label, "key" => item["key"], "label" => type.title(item), "action" => exists ? "update" : "add" }
    end
    gone = Array(package&.installed).reject { |r| items.any? { |i| i["type"] == r["type"] && i["key"] == r["key"] } }
    plan + gone.map { |r| { "type" => r["type"], "type_label" => item_type(r["type"])&.label, "key" => r["key"], "label" => r["key"], "action" => "remove" } }
  end

  # Instala ou atualiza (mesma key no local). Tudo ou nada.
  def install!(site, manifest, url)
    errs = errors(manifest, site)
    raise Error, errs.first(5).join(" ") if errs.any?

    package = site.packages.find_or_initialize_by(key: manifest["key"])
    ActiveRecord::Base.transaction do
      refs = manifest["items"].map do |item|
        type = item_type(item["type"])
        old = package.ref(type.key, item["key"])
        { "type" => type.key, "key" => item["key"], "id" => type.install!(site, item, package, old&.dig("id")) }
      end
      Array(package.installed).each do |r|
        next if refs.any? { |n| n["type"] == r["type"] && n["key"] == r["key"] }

        item_type(r["type"])&.uninstall!(site, r)
      end
      package.update!(name: manifest["name"].to_s.strip.first(120), version: manifest["version"], source_url: url, manifest: manifest, installed: refs)
    end
    DeviceMaps.reset!
    package
  end

  def uninstall!(package)
    ActiveRecord::Base.transaction do
      Array(package.installed).each { |r| item_type(r["type"])&.uninstall!(package.site, r) }
      package.destroy!
    end
    DeviceMaps.reset!
  end

  # Versão nova na fonte? → [manifesto, url, mais nova?]
  def check(package)
    manifest, url = fetch(package.source_url)
    [ manifest, url, newer?(manifest["version"], package.version) ]
  end

  def newer?(a, b)
    Gem::Version.new(a.to_s.tr("-+", "..")) > Gem::Version.new(b.to_s.tr("-+", ".."))
  rescue ArgumentError
    a.to_s != b.to_s
  end

  module Sources
    # https://github.com/dono/repo[.git][/tree/ref] → manifesto na raiz (raw).
    class GithubRepo
      RE = %r{\Ahttps://github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:/tree/([\w./-]+?))?/?\z}

      def self.match?(url) = RE.match?(url)

      def self.candidates(url)
        owner, repo, ref = RE.match(url).captures
        FILES.map { |f| "https://raw.githubusercontent.com/#{owner}/#{repo}/#{ref || 'HEAD'}/#{f}" }
      end
    end

    # https://gitlab.com/grupo/repo[.git] → manifesto na raiz (raw).
    class GitlabRepo
      RE = %r{\Ahttps://gitlab\.com/([\w./-]+?)(?:\.git)?/?\z}

      def self.match?(url) = RE.match?(url) && !url.include?("/-/")
      def self.candidates(url) = FILES.map { |f| "https://gitlab.com/#{RE.match(url)[1]}/-/raw/HEAD/#{f}" }
    end

    # URL https direta do manifesto (.json, .yml ou .yaml).
    class ManifestUrl
      def self.match?(url) = url.match?(%r{\Ahttps://[^\s]+\.(json|ya?ml)(\?[^\s]*)?\z}i)
      def self.candidates(url) = [ url ]
    end
  end

  module Items
    class Base
      extend PluginTexts
      translates :label

      class << self
        attr_reader :key

        def describe(key:, label:)
          @key = key
          @label = label
        end

        def title(item) = item["name"].presence || item["key"]
        def errors(_site, _item) = []
        # → id do registro criado/atualizado (ou nil quando não há registro próprio).
        def install!(_site, _item, _package, _old_id) = nil
        def uninstall!(_site, _ref) = nil
        # Onde abrir o registro instalado (nil = sem tela própria).
        def path(_ref) = nil
        def routes = Rails.application.routes.url_helpers
      end
    end

    # Mapa de dados de aparelho (código Tuya, propriedade MIoT → ponto): só
    # dados, nas seções que `DeviceMaps::MERGEABLE` deixa (nada de regex).
    class DeviceMapItem < Base
      describe key: "device_map", label: "Mapa de dados"
      texts "pt-BR" => { or: "ou", map: "map precisa ser %{maps}.", data: "data precisa ser um objeto.", sections: "seções não permitidas: %{extra} (só %{allowed}).",
                         plain: "%{key} precisa ser objeto ou lista de dados simples." },
            en: { label: "Data map", or: "or", map: "map must be %{maps}.", data: "data must be an object.", sections: "sections not allowed: %{extra} (only %{allowed}).",
                  plain: "%{key} must be an object or a list of plain data." },
            es: { label: "Mapa de datos", or: "o", map: "map debe ser %{maps}.", data: "data debe ser un objeto.", sections: "secciones no permitidas: %{extra} (solo %{allowed}).",
                  plain: "%{key} debe ser un objeto o una lista de datos simples." }

      def self.title(item) = "#{item['name'].presence || item['key']} (#{item['map']})"

      def self.errors(_site, item)
        allowed = DeviceMaps::MERGEABLE[item["map"].to_s] or return [ text(:map, maps: DeviceMaps::MERGEABLE.keys.join(" #{text(:or)} ")) ]
        data = item["data"]
        return [ text(:data) ] unless data.is_a?(Hash) && data.any?

        extra = data.keys - allowed
        return [ text(:sections, extra: extra.join(", "), allowed: allowed.join(", ")) ] if extra.any?

        data.filter_map { |k, v| text(:plain, key: k) unless DeviceMaps.plain?(v) }
      end
    end

    # Blueprint (modelo de automação ou script): valida pelo próprio Blueprint.
    class BlueprintItem < Base
      describe key: "blueprint", label: "Blueprint"
      texts en: { label: "Blueprint" }, es: { label: "Blueprint" }

      def self.build(site, item, record = nil)
        record ||= site.blueprints.new
        record.assign_attributes(name: item["name"], description: item["description"], domain: item["domain"] || "automation",
                                 mode: item["mode"] || "single", inputs: item["inputs"] || [], definition: item["definition"] || {})
        record
      end

      def self.errors(site, item) = build(site, item).tap(&:valid?).errors.full_messages

      def self.install!(site, item, package, old_id)
        record = (old_id && site.blueprints.find_by(id: old_id)) || site.blueprints.new
        build(site, item, record).tap { |b| b.source = "package:#{package.key || item['key']}" }.save!
        record.id
      end

      def self.uninstall!(site, ref) = site.blueprints.find_by(id: ref["id"])&.destroy!
      def self.path(ref) = routes.blueprint_path(ref["id"])
    end

    # Modelo de painel: um dashboard novo do local (o formato da F5).
    class DashboardItem < Base
      describe key: "dashboard", label: "Modelo de painel"
      texts en: { label: "Dashboard template" }, es: { label: "Plantilla de panel" }

      def self.errors(_site, item)
        return [ I18n.t("packages.errors.name") ] if item["name"].blank?

        Dashboards::Schema.errors(item["definition"].to_h)
      end

      def self.install!(site, item, _package, old_id)
        record = (old_id && site.dashboards.find_by(id: old_id)) || site.dashboards.new(kind: "custom")
        record.update!(name: item["name"], icon: item["icon"].presence_in(HelperTypes::ICONS), definition: item["definition"])
        record.id
      end

      def self.uninstall!(site, ref) = site.dashboards.find_by(id: ref["id"])&.destroy!
      def self.path(ref) = routes.dashboard_path(ref["id"])
    end

    # Helper (qualquer tipo de HelperTypes): `helper` = tipo, `form` = os
    # campos do formulário dele. Validado pelo plugin do tipo.
    class HelperItem < Base
      describe key: "helper", label: "Helper"
      texts "pt-BR" => { unknown: "helper \"%{helper}\" não existe (%{list})." },
            en: { label: "Helper", unknown: "helper \"%{helper}\" doesn't exist (%{list})." },
            es: { label: "Helper", unknown: "el helper \"%{helper}\" no existe (%{list})." }

      def self.form(item) = item["form"].to_h.stringify_keys.merge("name" => item["name"])

      def self.errors(site, item)
        plugin = HelperTypes.plugin(item["helper"]) or return [ text(:unknown, helper: item["helper"], list: HelperTypes.keys.join(", ")) ]
        point = HelperTypes.build(site, plugin)
        point.assign_attributes(name: item["name"])
        plugin.assign(point, form(item))
        point.errors.full_messages + (point.name.blank? ? [ I18n.t("packages.errors.name") ] : [])
      end

      def self.install!(site, item, _package, old_id)
        point = (old_id && site.points.helpers.find_by(id: old_id)) || HelperTypes.build(site, HelperTypes.plugin(item["helper"]))
        raise Error, "Helper #{item['name']}: #{point.errors.full_messages.to_sentence}" unless HelperTypes.save(point, form(item))

        point.id
      end

      def self.uninstall!(site, ref) = site.points.helpers.find_by(id: ref["id"])&.destroy!
      def self.path(ref) = routes.edit_helper_path(ref["id"])
    end
  end
end

module Packages
  module Items
    # ondaA2 A20: card de painel de terceiros (JS), conferido pelo SHA-256 e
    # isolado num iframe sandbox (Cards). O registro é o próprio hash.
    class CardItem < Base
      describe key: "card", label: "Card de painel"
      texts "pt-BR" => { url: "url precisa ser https e terminar em .js.", element: "element precisa ser o nome do elemento do card (ex.: meu-card)." },
            en: { label: "Dashboard card", url: "url must be https and end in .js.", element: "element must be the card element name (e.g. my-card)." },
            es: { label: "Tarjeta de panel", url: "url debe ser https y terminar en .js.", element: "element debe ser el nombre del elemento de la tarjeta (ej.: mi-tarjeta)." }

      def self.errors(_site, item)
        list = []
        list << text(:url) unless item["url"].to_s.match?(%r{\Ahttps://\S+\.js(\?\S*)?\z})
        list << I18n.t("cards.errors.sha") unless Cards.hex(item["sha256"])
        list << text(:element) unless item["element"].to_s.match?(Cards::ELEMENT)
        list
      end

      def self.install!(_site, item, _package, _old_id) = Cards.fetch!(item["url"], item["sha256"])
    end
  end
end
