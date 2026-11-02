module Web
  # Meus aparelhos (Lote 1, Configurações → Minha conta): os navegadores e a
  # PWA inscritos no Web Push desta pessoa. O navegador assina com a chave
  # VAPID pública e manda a inscrição (JSON); "Enviar teste" manda um aviso só
  # para a pessoa, por todos os transportes.
  class PushSubscriptionsController < ApplicationController
    def index
      @subscriptions = current_user.push_subscriptions.ordered
      @apps = current_user.device_tokens.order(created_at: :desc)
    end

    def create
      sub = PushSubscription.find_or_initialize_by(endpoint: params.require(:endpoint).to_s)
      sub.assign_attributes(user: current_user, p256dh_key: params.dig(:keys, :p256dh), auth_key: params.dig(:keys, :auth),
                            user_agent: request.user_agent.to_s.truncate(250))
      sub.name = params[:name].to_s.squish.truncate(60).presence || sub.name || PushSubscription.guess_name(request.user_agent)
      sub.save!
      render json: { id: sub.id, name: sub.name }, status: :created
    rescue ActiveRecord::RecordInvalid, ActionController::ParameterMissing => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    def destroy
      current_user.push_subscriptions.find(params[:id]).destroy!
      redirect_to push_subscriptions_path, notice: t("notices.push_removed")
    end

    def test
      return redirect_to(push_subscriptions_path, alert: t("notices.push_off")) if Push.transports.empty?

      Notifier.notify!(kind: "sistema", user: current_user, title: "Teste de aviso", body: "Se você leu isto no aparelho, o push está funcionando.",
                       data: { "url" => push_subscriptions_path, "tag" => "teste-push" })
      redirect_to push_subscriptions_path, notice: t("notices.push_test")
    end
  end
end
