module Api
  module V1
    # Webhook das automações (gatilho `webhook`): `POST /api/v1/hooks/automations/:token`
    # com JSON (até 10 KB), sem login; o token (gerado na automação) é a
    # credencial. O corpo chega no gatilho como `trigger.data`. Responde 202
    # com a execução, ou 404 se o token não existe ou a automação está
    # desligada/sem gatilho webhook.
    class AutomationHooksController < ActionController::API
      MAX_BYTES = 10_240

      rate_limit to: 60, within: 1.minute, by: -> { params[:token].to_s.first(16) }

      def create
        return render(json: { error: { code: "payload_too_large", message: "Corpo maior que 10 KB." } }, status: :content_too_large) if request.content_length.to_i > MAX_BYTES

        automation = ActsAsTenant.without_tenant { Automation.find_by(webhook_token: params[:token].to_s) }
        return render(json: { error: { code: "not_found", message: "Webhook não encontrado." } }, status: :not_found) unless automation&.enabled && automation.webhook?

        run = ActsAsTenant.with_tenant(automation.tenant) do
          automation.fire!({ "type" => "webhook", "title" => "Webhook", "data" => request.request_parameters.except("token") })
        end
        render json: { data: { run_id: run&.id, status: run&.status || "ignored" } }, status: :accepted
      end
    end
  end
end
