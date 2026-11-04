module Packages
  # Catálogo da loja (aba "Explorar"): a lista curada de pacotes, como a
  # lista padrão do HACS. O oficial é o `index.json` do repositório
  # público minhasuite/minha-automacao-marketplace; `PACKAGES_CATALOGS`
  # (URLs https separadas por espaço) troca ou soma outros catálogos no
  # mesmo formato. O catálogo só aponta: o pacote é baixado, mostrado e
  # validado pelo caminho de sempre (Packages.fetch → prévia → instalar).
  #
  #   { "format": 1, "name": "...", "packages": [
  #     { "key", "name", "description", "url", "author", "tags": [], "official": true } ] }
  #
  # Entrada com URL que não é fonte de pacote (Packages::SOURCES) ou chave
  # inválida fica de fora; catálogo que não responde vira aviso e não
  # derruba a tela. Lido pelo SafeHttp e guardado por `TTL`.
  module Catalog
    OFFICIAL = "https://raw.githubusercontent.com/minhasuite/minha-automacao-marketplace/main/index.json".freeze
    TTL = 1.hour
    MAX_BYTES = 256 * 1024
    MAX_ENTRIES = 300
    KEY = /\A[a-z0-9_-]{2,60}\z/
    Entry = Data.define(:key, :name, :description, :url, :author, :tags, :official, :catalog)
    Result = Data.define(:entries, :errors)

    module_function

    def urls = (ENV["PACKAGES_CATALOGS"].presence || OFFICIAL).split.select { |u| u.start_with?("https://") }.uniq

    # → Result (entradas de todos os catálogos, sem repetir chave; a do primeiro vale).
    def call(fetch: method(:download))
      errors = []
      entries = urls.flat_map do |url|
        parse(fetch.call(url), url)
      rescue Packages::Error, SafeHttp::Error, SafeHttp::Blocked, JSON::ParserError => e
        errors << I18n.t("packages.catalog.unreachable", url: url, error: e.message.truncate(120))
        []
      end
      Result.new(entries: entries.uniq(&:key), errors: errors)
    end

    def download(url)
      Rails.cache.fetch([ "packages/catalog", url ], expires_in: TTL) do
        res = SafeHttp.get(url, timeout: 15)
        raise Packages::Error, I18n.t("packages.errors.status", url: url, status: res.status) unless res.status == 200
        raise Packages::Error, I18n.t("packages.errors.too_big") if res.body.bytesize > MAX_BYTES

        res.body.to_s
      end
    end

    def parse(body, url)
      data = JSON.parse(body.to_s)
      raise Packages::Error, I18n.t("packages.errors.object") unless data.is_a?(Hash) && data["packages"].is_a?(Array)

      official = url == OFFICIAL
      data["packages"].first(MAX_ENTRIES).filter_map { |p| entry(p, official, data["name"].presence || url) }
    end

    def entry(p, official, catalog)
      return unless p.is_a?(Hash) && p["key"].to_s.match?(KEY) && p["name"].present?

      url = p["url"].to_s.strip
      return unless Packages.sources.any? { |s| s.match?(url) }

      Entry.new(key: p["key"].to_s, name: p["name"].to_s.first(80), description: p["description"].to_s.first(300),
                url: url, author: p["author"].to_s.first(60), tags: Array(p["tags"]).map(&:to_s).first(8),
                official: official && p["official"] != false, catalog: catalog.to_s.first(80))
    end

    # Filtro da tela: texto (nome, descrição, autor, etiquetas) e etiqueta.
    def search(entries, q: nil, tag: nil)
      words = q.to_s.downcase.split
      entries.select do |e|
        hay = [ e.name, e.description, e.author, *e.tags ].join(" ").downcase
        words.all? { |w| hay.include?(w) } && (tag.blank? || e.tags.include?(tag))
      end
    end
  end
end
