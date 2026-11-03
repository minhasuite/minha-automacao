module GoogleHome
  # HomeGraph do Google (ondaC1, C6): estado na hora (Report State) e "lista
  # mudou" (Request Sync), com a conta de serviço do projeto do dono (JSON
  # guardado cifrado na integração Google Home). Token pelo JWT RS256 da
  # própria conta (sem gem), guardado no cache até vencer.
  module HomeGraph
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
    API = "https://homegraph.googleapis.com/v1/devices".freeze
    SCOPE = "https://www.googleapis.com/auth/homegraph".freeze
    Error = Class.new(StandardError)

    module_function

    def integration(site) = site.integrations.find_by(driver: "google_home")
    def account(site) = (i = integration(site)) && JSON.parse(i.secrets["service_account"].to_s.presence || "null")
    def configured?(site) = account(site).is_a?(Hash) && account(site)["private_key"].present?
    def links(site) = ApiToken.active.where(client: "google", site_id: site.id).where.not(last_used_at: nil)

    def access_token(acc)
      Rails.cache.fetch("google_home:token:#{Digest::SHA256.hexdigest(acc['client_email'].to_s)}", expires_in: 50.minutes) do
        now = Time.now.to_i
        b64 = ->(h) { Base64.urlsafe_encode64(h.to_json, padding: false) }
        unsigned = "#{b64.call(alg: 'RS256', typ: 'JWT')}.#{b64.call(iss: acc['client_email'], scope: SCOPE, aud: TOKEN_URL, iat: now, exp: now + 3600)}"
        sig = OpenSSL::PKey::RSA.new(acc["private_key"]).sign(OpenSSL::Digest.new("SHA256"), unsigned)
        res = post(TOKEN_URL, URI.encode_www_form(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: "#{unsigned}.#{Base64.urlsafe_encode64(sig, padding: false)}"),
                   "Content-Type" => "application/x-www-form-urlencoded")
        res["access_token"] or raise Error, "Google não deu o token da conta de serviço."
      end
    end

    # Estado dos pontos para todas as contas ligadas ao local.
    def report_state!(site, points)
      acc = account(site) or return 0
      states = points.select { |p| GoogleHome.exposed?(p) }.to_h { |p| [ p.id, GoogleHome.state(p) ] }
      return 0 if states.empty?

      links(site).sum do |t|
        call(acc, "reportStateAndNotification", "requestId" => SecureRandom.uuid, "agentUserId" => GoogleHome.agent_user_id(t), "payload" => { "devices" => { "states" => states } })
        1
      end
    end

    def request_sync!(site)
      acc = account(site) or raise Error, "Sem conta de serviço."
      links(site).sum { |t| call(acc, "requestSync", "agentUserId" => GoogleHome.agent_user_id(t), "async" => true) && 1 }
    end

    def call(acc, method, body) = post("#{API}:#{method}", body.to_json, "Content-Type" => "application/json", "Authorization" => "Bearer #{access_token(acc)}")

    def post(url, body, headers)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 10) { |h| h.post(uri.request_uri, body, headers) }
      raise Error, "Google respondeu #{res.code} em #{uri.path}." unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body.presence || "{}")
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => e
      raise Error, "Sem resposta do Google (#{e.class.name.demodulize})."
    end
  end
end
