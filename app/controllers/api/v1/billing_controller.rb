module Api
  module V1
    # Assinatura da empresa pela Google Play. O app manda o
    # comprovante; quem decide se vale é o servidor, perguntando à Play.
    class BillingController < BaseController
      before_action :require_app_token!

      # GET /billing
      def show
        Licencas::Sync.throttled(current_tenant_record)
        render_data(Billing::Status.call(current_tenant_record.reload, current_user))
      end

      # POST /billing/google/verify { purchase_token }
      def verify_google
        sub = Billing::PlaySync.call(params.require(:purchase_token), user: current_user)
        return render_error(:verification_failed, "Compra não reconhecida.", status: :unprocessable_content) if sub.nil?

        render_data(Billing::Status.call(current_tenant_record.reload, current_user))
      rescue Billing::PlaySync::Error, Billing::GooglePlay::Error => e
        Rails.logger.warn("[billing] verificação falhou: #{e.message}")
        render_error(:verification_failed, "Não foi possível confirmar a compra com a Google Play.", status: :unprocessable_content)
      end

      private

      # Chave de serviço é só leitura e não compra.
      def require_app_token!
        render_error(:forbidden, "Só pelo app.", status: :forbidden) if @current_scopes
      end
    end
  end
end
