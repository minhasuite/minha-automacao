require "net/http"

# Atualização do servidor (produto): de onde vem a versão nova é um registro
# (`SOURCES`; hoje as releases do GitHub, a tag da release = tag da imagem no
# GHCR) e quem atualiza é o supervisor (`POST /system/update`), que roda o
# bin/ma-update num container à parte: backup do banco, troca a imagem no
# .env, sobe o compose e volta sozinho para a imagem anterior se o /up não
# responder. O andamento fica em backups/update-status.json (o app lê em
# /backups, montado só leitura). Sem supervisor (VPS de demonstração) a tela
# só mostra a versão.
module Updates
  SOURCES = %w[GithubReleases].freeze
  IMAGE_REPO = "ghcr.io/minhasuite/minha-automacao".freeze
  TAG = /\A[\w][\w.-]{0,63}\z/
  CACHE_KEY = "updates/latest".freeze
  Error = Class.new(StandardError)

  module_function

  def sources = SOURCES.map { |n| const_get(n) }
  def source = sources.find { |s| s.key == ENV["UPDATE_SOURCE"] } || sources.first

  # Imagem que está rodando (o .env do servidor tem IMAGE=...; a VPS não).
  def current_image = ENV["IMAGE"].presence || "#{IMAGE_REPO}:latest"
  def current_tag = current_image.split(":").last
  def current_commit = ENV["APP_VERSION"].presence&.first(7)

  # Última versão publicada → {"tag", "name", "notes", "url", "published_at"} ou nil (cache de 6 h).
  # Só onde dá para atualizar (servidor local com supervisor).
  def latest(force: false)
    return nil unless supported?

    Rails.cache.fetch(CACHE_KEY, expires_in: 6.hours, force: force) { source.latest }
  rescue Error, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, JSON::ParserError, IOError => e
    Rails.logger.info("[updates] #{e.message}")
    nil
  end

  def available?(release) = release.present? && release["tag"] != current_tag
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

    def latest
      uri = URI("https://api.github.com/repos/#{repo}/releases/latest")
      req = Net::HTTP::Get.new(uri, "Accept" => "application/vnd.github+json", "User-Agent" => "minha-automacao")
      req["Authorization"] = "Bearer #{ENV['UPDATE_TOKEN']}" if ENV["UPDATE_TOKEN"].present?
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
      return nil if res.code == "404" # nenhuma release ainda
      raise Error, "GitHub respondeu #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      j = JSON.parse(res.body)
      { "tag" => j["tag_name"].to_s, "name" => j["name"].presence || j["tag_name"], "notes" => j["body"].to_s.truncate(4000),
        "url" => j["html_url"], "published_at" => j["published_at"] }
    end
  end
end
