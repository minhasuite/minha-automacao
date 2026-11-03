module Apps
  # Cliente do supervisor dos aplicativos (supervisor/server.rb, F8g). O Rails
  # nunca fala com o Docker: só com esta API interna, com o token do `.env`.
  # Sem SUPERVISOR_URL (VPS) a tela mostra só o catálogo.
  module Supervisor
    Error = Class.new(StandardError)

    module_function

    def configured? = ENV["SUPERVISOR_URL"].present? && ENV["SUPERVISOR_TOKEN"].present?

    # {chave → status} de todos os apps do catálogo.
    def statuses = request(:get, "/apps").fetch("data").index_by { |s| s["key"] }
    def status(key) = request(:get, "/apps/#{key}").fetch("data")
    def logs(key, lines = 200) = request(:get, "/apps/#{key}/logs?lines=#{lines.to_i}").dig("data", "lines").to_s
    # resto (7.13): app de terceiro leva o manifesto (o supervisor valida de novo).
    def install(key, options:, boot:, watchdog:, manifest: nil) = request(:post, "/apps/#{key}/install", { options:, boot:, watchdog:, manifest: }.compact)
    def configure(key, **body) = request(:put, "/apps/#{key}/config", body)
    def upgrade(key, manifest: nil) = request(:post, "/apps/#{key}/update", ({ manifest: } if manifest))
    def act(key, action) = request(:post, "/apps/#{key}/#{action}")
    def uninstall(key, keep_data:) = request(:delete, "/apps/#{key}?keep_data=#{keep_data ? 1 : 0}")

    def request(method, path, body = nil)
      raise Error, "Os aplicativos rodam no servidor local." unless configured?

      uri = URI.join(ENV.fetch("SUPERVISOR_URL"), path)
      req = Net::HTTP.const_get(method.to_s.capitalize).new(uri, "Authorization" => "Bearer #{ENV.fetch('SUPERVISOR_TOKEN')}",
                                                                 "Content-Type" => "application/json")
      req.body = body.to_json if body
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 20) { |h| h.request(req) }
      data = JSON.parse(res.body.presence || "{}")
      return data if res.is_a?(Net::HTTPSuccess)

      raise Error, [ data["error"], data["errors"]&.map { |k, v| "#{k}: #{v}" }&.join(", ") ].compact.join(" ").presence || "Supervisor respondeu #{res.code}."
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError, IOError
      raise Error, "Supervisor dos aplicativos fora do ar."
    end
  end
end
