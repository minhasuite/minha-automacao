# Webhook de mensageiro (Pacote 4): `GET|POST /mensageiros/:id`, sem sessão.
# Quem valida (segredo, assinatura, verificação) é o plugin da integração
# (`webhook(integração, request)` → [status, corpo]); aqui só se acha a
# integração. Sem plugin com webhook = 404.
class MessengerWebhooksController < ActionController::API
  def receive
    integration = ActsAsTenant.without_tenant { Integration.find_by(id: params[:id]) }
    return head(:not_found) unless integration&.plugin.respond_to?(:webhook)

    status, body = ActsAsTenant.with_tenant(integration.tenant) { integration.plugin.webhook(integration, request) }
    render plain: body, status: status
  end
end
