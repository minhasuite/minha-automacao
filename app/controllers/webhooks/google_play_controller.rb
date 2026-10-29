module Webhooks
  # RTDN da Google Play (renovação, cancelamento, estorno, retomada) pelo
  # Pub/Sub push (copiado do minhas-compras). O aviso diz QUAL comprovante
  # mexeu; o que mudou se reconsulta na Play (mesmo caminho da verificação).
  # Responde 200 mesmo sem processar: o Pub/Sub reentrega em loop sem 200.
  class GooglePlayController < ActionController::API
    def create
      return head(:unauthorized) unless valid_token?

      note = decode_message
      token = note.dig("subscriptionNotification", "purchaseToken") || note.dig("voidedPurchaseNotification", "purchaseToken")
      Billing::PlaySync.call(token) if token.present? && note["packageName"] == Billing::PlayConfig.package
      head :ok
    rescue Billing::PlaySync::Error, Billing::GooglePlay::Error, JSON::ParserError, ArgumentError => e
      Rails.logger.warn("[play-rtdn] ignorado: #{e.class} #{e.message}")
      head :ok
    end

    private

    # Segredo na URL do push. Sem env o webhook fica fechado.
    def valid_token?
      expected = ENV["PLAY_RTDN_TOKEN"].to_s
      given = params[:token].to_s
      expected.present? && given.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)
    end

    def decode_message
      data = params.dig(:message, :data).to_s
      data.blank? ? {} : JSON.parse(Base64.decode64(data))
    end
  end
end
