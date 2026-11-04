require "net/http"

# Atualização do servidor (produto): de onde vem a versão nova é um registro
# (`SOURCES`; hoje as releases do GitHub, a tag da release = tag da imagem no
# GHCR) e quem atualiza é o supervisor (`POST /system/update`), que roda o
# bin/ma-update num container à parte: backup do banco, troca a imagem no
# .env, sobe o compose e volta sozinho para a imagem anterior se o /up não
# responder. O andamento fica em backups/update-status.json (o app lê em
# /backups, montado só leitura). Sem supervisor (VPS de demonstração) a tela
# só mostra a versão.
#
# Canais (distribuição): "stable" lê a última release estável; "beta", a
# última pré-release (cada master verde gera uma `vX.Y.Z-beta.N`; a estável
# é uma beta promovida, `.github/workflows/promover-estavel.yml`). Atualizar
# sozinho (`Auto`) roda numa janela de horário e só pega estável publicada há
# AUTO_MIN_AGE. A escolha fica em storage/update-settings.json (é do
# servidor, não de um tenant).
module Updates
  SOURCES = %w[GithubReleases].freeze
  IMAGE_REPO = "ghcr.io/minhasuite/minha-automacao".freeze
  TAG = /\A[\w][\w.-]{0,63}\z/
  CACHE_KEY = "updates/latest".freeze
  CHANNELS = %w[stable beta].freeze
  VERSION = /\Av?(\d+\.\d+\.\d+)(?:-([\w.]+))?\z/
  DEFAULTS = { "channel" => "stable", "auto" => false, "window_start" => 3 }.freeze
  WINDOW_HOURS = 2
  AUTO_MIN_AGE = 2.days
  Error = Class.new(StandardError)

  module_function

  def sources = SOURCES.map { |n| const_get(n) }
  def source = sources.find { |s| s.key == ENV["UPDATE_SOURCE"] } || sources.first

  # Imagem que está rodando (o .env do servidor tem IMAGE=...; a VPS não).
  def current_image = ENV["IMAGE"].presence || "#{IMAGE_REPO}:latest"
  # A versão gravada na imagem pelo CI (RELEASE_TAG) vale mais que a tag do .env (`latest-stable`).
  def current_tag = ENV["RELEASE_TAG"].presence || current_image.split(":").last
  def current_commit = ENV["APP_VERSION"].presence&.first(7)

  # Última versão publicada → {"tag", "name", "notes", "url", "published_at"} ou nil (cache de 6 h).
  # Só onde dá para atualizar (servidor local com supervisor).
  def latest(force: false)
    return nil unless supported?

    Rails.cache.fetch("#{CACHE_KEY}/#{channel}", expires_in: 6.hours, force: force) { source.latest(channel) }
  rescue Error, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError, IOError => e
    Rails.logger.info("[updates] #{e.message}")
    nil
  end

  def available?(release) = release.present? && newer?(release["tag"], current_tag)

  # "v1.2.3" / "v1.2.3-beta.4" → Gem::Version (beta < estável do mesmo número); outra coisa → nil.
  def version(tag)
    m = VERSION.match(tag.to_s) or return nil
    Gem::Version.new(m[2] ? "#{m[1]}.pre.#{m[2]}" : m[1])
  end

  # A release é mais nova que a instalada? Tag fora do padrão (latest, sha-*) = só "diferente".
  # Rodando a beta X.Y.Z-beta.N, a estável X.Y.Z não conta: ela é uma beta
  # anterior promovida, e voltar código pode desfazer migração.
  def newer?(tag, current)
    a = version(tag)
    b = version(current)
    return tag.to_s != current.to_s unless a && b
    return false if b.prerelease? && !a.prerelease? && a.release == b.release

    a > b
  end

  # Configuração da atualização (canal, atualizar sozinho, janela), por servidor.
  def settings_file = ENV.fetch("UPDATE_SETTINGS_FILE") { Rails.root.join("storage", "update-settings.json").to_s }

  def settings
    data = File.exist?(settings_file) ? JSON.parse(File.read(settings_file)) : {}
    DEFAULTS.merge(data.is_a?(Hash) ? data : {})
  rescue JSON::ParserError, SystemCallError
    DEFAULTS.dup
  end

  def save_settings!(patch)
    data = settings.merge(patch.to_h.stringify_keys)
    FileUtils.mkdir_p(File.dirname(settings_file))
    File.write("#{settings_file}.tmp", JSON.generate(data))
    File.rename("#{settings_file}.tmp", settings_file)
    data
  end

  def channel = CHANNELS.include?(settings["channel"]) ? settings["channel"] : "stable"

  # Formulário da tela: canal, ligar/desligar e hora de início da janela (0–23).
  def configure!(channel:, auto:, window_start:)
    raise Error, I18n.t("updates.bad_channel") unless CHANNELS.include?(channel.to_s)

    hour = Integer(window_start.to_s, exception: false)
    raise Error, I18n.t("updates.bad_window") unless hour&.between?(0, 23)

    save_settings!("channel" => channel.to_s, "auto" => ActiveModel::Type::Boolean.new.cast(auto) == true, "window_start" => hour)
    Rails.cache.delete("#{CACHE_KEY}/#{channel}")
  end

  def in_window?(time = Time.current)
    start = settings["window_start"].to_i
    ((time.hour - start) % 24) < WINDOW_HOURS
  end
  def supported? = Apps::Supervisor.configured?

  # Pede ao supervisor para atualizar para a tag (só a imagem deste produto).
  def start!(tag)
    raise Error, I18n.t("updates.bad_tag") unless tag.to_s.match?(TAG)
    raise Error, I18n.t("updates.unsupported") unless supported?

    Apps::Supervisor.request(:post, "/system/update", { image: "#{IMAGE_REPO}:#{tag}" })
  rescue Apps::Supervisor::Error => e
    raise Error, e.message
  end

  # Andamento da última atualização: {"state" (running|done|rolled_back|failed), "step", "from", "to", "at", "message"}.
  def status(file = ENV.fetch("UPDATE_STATUS_FILE", "/backups/update-status.json"))
    File.exist?(file) ? JSON.parse(File.read(file)) : {}
  rescue JSON::ParserError, SystemCallError
    {}
  end

  # Fonte: releases do GitHub (UPDATE_REPO, padrão o do produto; UPDATE_TOKEN só se o repositório for privado).
  module GithubReleases
    module_function

    def key = "github"
    def repo = ENV.fetch("UPDATE_REPO", "minhasuite/minha-automacao")

    # stable: a última release (o GitHub já ignora pré-release e rascunho);
    # beta: a pré-release de número maior entre as recentes.
    def latest(channel = "stable")
      return release(get("releases/latest")) unless channel == "beta"

      list = Array(get("releases?per_page=30")).select { |j| j["prerelease"] && !j["draft"] && Updates.version(j["tag_name"]) }
      release(list.max_by { |j| Updates.version(j["tag_name"]) })
    end

    def get(path)
      uri = URI("https://api.github.com/repos/#{repo}/#{path}")
      req = Net::HTTP::Get.new(uri, "Accept" => "application/vnd.github+json", "User-Agent" => "minha-automacao")
      req["Authorization"] = "Bearer #{ENV['UPDATE_TOKEN']}" if ENV["UPDATE_TOKEN"].present?
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
      return nil if res.code == "404" # nenhuma release ainda
      raise Error, "GitHub respondeu #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end

    def release(j)
      return nil unless j.is_a?(Hash) && j["tag_name"].present?

      { "tag" => j["tag_name"].to_s, "name" => j["name"].presence || j["tag_name"], "notes" => j["body"].to_s.truncate(4000),
        "url" => j["html_url"], "published_at" => j["published_at"], "prerelease" => j["prerelease"] == true }
    end
  end
end
