require "googleauth"
require "net/http"

module Push
  # Push nativo via FCM HTTP v1. Credencial vazia = desligado (no-op).
  #   FCM_CREDENTIALS_JSON  JSON da conta de serviço
  #   FCM_PROJECT_ID        projeto Firebase (opcional; senão vem do JSON)
  module FcmService
    SCOPE = "https://www.googleapis.com/auth/firebase.messaging".freeze

    module_function

    def configured? = ENV["FCM_CREDENTIALS_JSON"].present?

    def project_id = ENV["FCM_PROJECT_ID"].presence || JSON.parse(ENV.fetch("FCM_CREDENTIALS_JSON"))["project_id"]

    # => true (enviado) | :unregistered (token morto) | :retry (429/5xx, recusa sem efeito) | false
    # Conexão que não abre levanta (o Push::Fcm decide a nova tentativa).
    def deliver(token, title:, body:, data: {})
      return false unless configured?

      post(message: { token: token, notification: { title: title, body: body },
                      data: data.transform_keys(&:to_s).transform_values(&:to_s), android: { priority: "high" } })
    end

    def post(payload)
      uri = URI("https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{access_token}"
      req["Content-Type"] = "application/json"
      req.body = payload.to_json
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
      return true if res.is_a?(Net::HTTPSuccess)
      return :unregistered if res.code == "404"
      return :retry if Transient::STATUSES.include?(res.code.to_i)

      Rails.logger.warn("[fcm] envio falhou #{res.code}")
      false
    end

    # Push só de DADOS (sem notificação): acorda o app em segundo plano.
    # => true | :unregistered | :retry | false
    def deliver_data(token, data:)
      return false unless configured?

      post(message: { token: token, data: data.transform_keys(&:to_s).transform_values(&:to_s), android: { priority: "high" } })
    end

    def access_token
      @authorizer ||= Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(ENV.fetch("FCM_CREDENTIALS_JSON")), scope: SCOPE
      )
      @authorizer.fetch_access_token! if @authorizer.access_token.nil? || @authorizer.expires_within?(60)
      @authorizer.access_token
    end
  end
end
