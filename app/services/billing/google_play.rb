require "googleauth"
require "net/http"

module Billing
  # Estado de uma assinatura na Google Play Developer API
  # (`purchases.subscriptionsv2`). O comprovante do celular só vale depois
  # desta consulta — o cliente nunca é a fonte da verdade. (Do meu-personal,
  # mais base plan, oferta, teste grátis e renovação automática.)
  class GooglePlay
    class Error < StandardError; end

    BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3".freeze

    STATES = {
      "SUBSCRIPTION_STATE_ACTIVE" => "active",
      "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" => "grace",
      "SUBSCRIPTION_STATE_ON_HOLD" => "on_hold",
      "SUBSCRIPTION_STATE_PAUSED" => "paused",
      "SUBSCRIPTION_STATE_CANCELED" => "canceled",
      "SUBSCRIPTION_STATE_EXPIRED" => "expired",
      "SUBSCRIPTION_STATE_PENDING" => "pending"
    }.freeze

    # { status:, plan:, product_id:, base_plan_id:, offer_id:, trial:, auto_renewing:,
    #   expires_at:, linked_token:, account_id:, raw: } ou levanta Error.
    def self.subscription(purchase_token) = new.subscription(purchase_token)

    def subscription(purchase_token)
      raise Error, "Play billing desligado (sem conta de serviço)" unless PlayConfig.configured?
      raise Error, "purchase_token vazio" if purchase_token.blank?

      self.class.parse(get("/applications/#{PlayConfig.package}/purchases/subscriptionsv2/tokens/#{CGI.escape(purchase_token)}"))
    end

    def self.parse(json)
      line = Array(json["lineItems"]).max_by { |l| l["expiryTime"].to_s } || {}
      offer = line["offerDetails"] || {}
      status = STATES.fetch(json["subscriptionState"].to_s, "expired")
      trial = line.dig("offerPhase", "freeTrial").present? ||
              (offer["offerId"] == Plans::TRIAL_OFFER && (start = time(json["startTime"])) && start > Plans::TRIAL_DAYS.days.ago)
      status = "trial" if status == "active" && trial
      { status: status, product_id: line["productId"], plan: PlayConfig.plan_for(line["productId"]),
        base_plan_id: offer["basePlanId"], offer_id: offer["offerId"], trial: trial ? true : false,
        auto_renewing: line.dig("autoRenewingPlan", "autoRenewEnabled"), expires_at: time(line["expiryTime"]),
        linked_token: json["linkedPurchaseToken"].presence,
        account_id: json.dig("externalAccountIdentifiers", "obfuscatedExternalAccountId").presence, raw: json }
    end

    def self.time(value)
      value.present? ? Time.zone.parse(value) : nil
    rescue ArgumentError
      nil
    end

    private

    def get(path)
      uri = URI("#{BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 20
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{access_token}"
      res = http.request(req)
      raise Error, "Play API #{res.code}: #{res.body.to_s.truncate(300)}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    rescue JSON::ParserError => e
      raise Error, "resposta ilegível da Play: #{e.message}"
    end

    def authorizer
      @authorizer ||= Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: PlayConfig.credentials_io, scope: PlayConfig::SCOPE)
    end

    def access_token
      a = authorizer
      a.fetch_access_token! if a.access_token.nil? || (a.expires_at && a.expires_at <= Time.current + 60)
      a.access_token
    end
  end
end
