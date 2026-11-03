# Repositórios de aplicativos de terceiros (resto, 7.13; os repositórios de
# add-ons do HA). Repositório = um índice JSON ou YAML por https:
#   { name: "Meus apps", apps: [ { key: "meu_app", name:, category:, icon:,
#     description:, image: "ghcr.io/eu/app", version: "1.2.0",
#     digest: "sha256:<64 hexa>", ports:, volumes:, options:, env: … } ] }
# Cada app passa pela mesma validação do catálogo (AppCatalog::Manifest) e
# mais as regras de terceiro: imagem fixada por digest, sem `system` nem
# `server_env` (segredo do servidor), chave que não colide com a do produto.
# O supervisor valida de novo ao instalar e guarda o manifesto no container.
# ponytail: lista num arquivo em storage/ (só o web lê); tabela se precisar
# de histórico ou de vários servidores lendo.
module AppRepos
  Error = Class.new(StandardError)
  MAX_APPS = 50

  module_function

  def file = ENV.fetch("APP_REPOS_FILE") { Rails.root.join("storage", "app_repositories.json").to_s }

  def all
    JSON.parse(File.read(file))
  rescue Errno::ENOENT, JSON::ParserError
    []
  end

  def save!(list)
    FileUtils.mkdir_p(File.dirname(file))
    File.write("#{file}.tmp", JSON.pretty_generate(list))
    File.rename("#{file}.tmp", file)
  end

  # Manifestos de todos os repositórios (o AppCatalog junta com os do produto).
  def manifests
    all.flat_map do |repo|
      repo["apps"].to_h.filter_map do |key, data|
        AppCatalog.third_party(key, data, repository: repo["name"])
      rescue AppCatalog::Invalid
        nil
      end
    end
  end

  # Baixa e confere o índice → {"url", "name", "apps" => {chave → manifesto}}.
  def fetch(url)
    raise Error, I18n.t("resto.apps.errors.url") unless url.to_s.match?(%r{\Ahttps://\S+\z})

    res = SafeHttp.get(url, timeout: 15)
    raise Error, I18n.t("resto.apps.errors.download", status: res.status) if res.status >= 400

    data = url.match?(/\.ya?ml(\?|\z)/i) ? YAML.safe_load(res.body) : JSON.parse(res.body)
    apps = Array(data["apps"]).first(MAX_APPS)
    raise Error, I18n.t("resto.apps.errors.empty") unless data.is_a?(Hash) && apps.any?

    clean = apps.to_h do |a|
      key = a["key"].to_s
      AppCatalog.third_party(key, a.except("key"), repository: data["name"])
      [ key, a.except("key") ]
    end
    { "url" => url, "name" => data["name"].to_s.strip.first(80).presence || URI(url).host, "apps" => clean, "fetched_at" => Time.current.iso8601 }
  rescue SafeHttp::Error, JSON::ParserError, Psych::Exception => e
    raise Error, I18n.t("resto.apps.errors.read", error: e.message.truncate(120))
  rescue AppCatalog::Invalid => e
    raise Error, I18n.t("resto.apps.errors.invalid", error: e.message.truncate(160))
  end

  def add!(url, user:)
    repo = fetch(url)
    others = all.reject { |r| r["url"] == url }
    clash = repo["apps"].keys & others.flat_map { |r| r["apps"].to_h.keys }
    raise Error, I18n.t("resto.apps.errors.clash", keys: clash.join(", ")) if clash.any?

    save!(others + [ repo ])
    audit!(user, "add", url)
    repo
  end

  def remove!(url, user:)
    save!(all.reject { |r| r["url"] == url })
    audit!(user, "remove", url)
  end

  def audit!(user, action, url)
    AuditEvent.create!(tenant_id: user.tenant_id, user_id: user.id, action: "app_repository.#{action}", auditable_type: "App", details: { url: url })
  end
end
