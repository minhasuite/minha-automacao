module Api
  module V1
    # Token FCM do aparelho. Mesmo token em outra conta (troca de login no
    # aparelho) é reatribuído.
    class DeviceTokensController < BaseController
      # POST /device_tokens { token, platform? }
      def create
        token = params.require(:token).to_s
        record = DeviceToken.find_or_initialize_by(token: token)
        record.update!(user: current_user, platform: params[:platform].presence || "android", last_seen_at: Time.current)
        render_data({ token: record.token, platform: record.platform }, status: :created)
      end

      # DELETE /device_tokens/:token
      def destroy
        current_user.device_tokens.where(token: params[:token]).delete_all
        head :no_content
      end
    end
  end
end
