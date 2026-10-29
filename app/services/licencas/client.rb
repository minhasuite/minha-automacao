require "net/http"

module Licencas
  # Cliente do licenciamento central (licencas.minhasuite.com). Contrato em
  # licencas/docs/INTEGRACAO.md. URL ou chave vazia = desligado. Nunca está no
  # caminho do usuário: falha de rede ou HTTP vira log e nil.
  module Client
    TIMEOUT = 5

    module_function

    def enabled? = [ ENV["LICENCAS_URL"], ENV["LICENCAS_API_KEY"] ].all?(&:present?)

    # Idempotente por canal + id_externo.
    def report(attrs) = request(Net::HTTP::Post, "/api/v1/assinaturas", body: attrs)

    # Exclusão da empresa (LGPD).
    def delete_owner(owner_id) = request(Net::HTTP::Delete, "/api/v1/donos/#{ERB::Util.url_encode(owner_id)}")

    # => { "data" => nil | { "plano", "ciclo", "status", "expira_em", ... } }, ou nil se não respondeu.
    def rights(emails) = request(Net::HTTP::Get, "/api/v1/direitos", query: { emails: emails })

    def request(klass, path, body: nil, query: nil)
      return nil unless enabled?

      uri = URI("#{ENV['LICENCAS_URL'].chomp('/')}#{path}")
      uri.query = query.to_query if query
      req = klass.new(uri)
      req["X-Api-Key"] = ENV["LICENCAS_API_KEY"]
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = body.to_json
      end
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |h| h.request(req) }
      raise "HTTP #{res.code}: #{res.body.to_s.truncate(200)}" unless res.is_a?(Net::HTTPSuccess)

      res.body.present? ? JSON.parse(res.body) : {}
    rescue StandardError => e
      # Sem a query: ela leva e-mails.
      Rails.logger.warn("[licencas] #{klass.name.demodulize.upcase} #{path}: #{e.message}")
      Rails.error.report(e, handled: true, context: { licencas: path })
      nil
    end
  end
end
