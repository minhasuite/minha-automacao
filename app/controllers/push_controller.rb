# O que o service worker chama sem sessão (Lote 1):
# - POST /push/resposta {token, action_id}: botão tocado na notificação. O token
#   é assinado com a notificação e a pessoa (Notification#action_token) e vale
#   uma vez: 409 se o aviso já foi respondido, 404 se o token não vale.
#   `ma-mute` (Notification::MUTE_ACTION) silencia a origem do aviso para a pessoa.
# - GET /push/imagem?t=: quadro de câmera do aviso por id assinado com
#   validade (o go2rtc nunca fica exposto).
class PushController < ActionController::API
  def respond
    notification, user = Notification.from_action_token(params[:token])
    return head(:not_found) unless notification

    ActsAsTenant.with_tenant(notification.tenant) do
      Current.user = user
      # "Silenciar" do push: não responde ao aviso (pode tocar de novo depois).
      next(notification.mute!(user) ? head(:no_content) : head(:unprocessable_content)) if params[:action_id] == Notification::MUTE_ACTION

      notification.respond!(params[:action_id], user) ? head(:no_content) : head(:conflict)
    end
  rescue ArgumentError
    head :unprocessable_content
  end

  def image
    n = ActsAsTenant.without_tenant { Notification.find_signed(params[:t].to_s, purpose: :push_image) }
    return head(:not_found) unless n&.image&.attached?

    response.headers["Cache-Control"] = "private, max-age=3600"
    send_data n.image.download, type: n.image.content_type, disposition: "inline"
  end
end
