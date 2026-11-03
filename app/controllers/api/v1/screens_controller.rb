module Api
  module V1
    # Telas do servidor (appweb, docs/app.md): a página da web transcodificada
    # em blocos (AppScreen) para o app desenhar nativo. Quem pode o quê é o
    # mesmo controlador da web que decide (papel no local, dono, administrador).
    #   GET  /screen?path=/configuracoes/saude          → {data: página | json | download | external}
    #   POST /screen {path, method, fields: [[nome, valor], …]} → o envio do formulário e a tela seguinte
    #   POST /screen/bridge {to}                         → link de uso único que abre `to` no navegador já logado
    class ScreensController < BaseController
      rescue_from AppScreen::Denied do
        render_error(:not_found, I18n.t("appweb.not_allowed"), status: :not_found)
      end

      def show = respond_with(AppScreen.dispatch(user: current_user, verb: "get", path: params.require(:path), fields: nil, request: request))

      def create
        verb = params[:method].to_s.downcase.presence_in(%w[get post patch put delete]) || "post"
        fields = request.request_parameters["fields"]
        respond_with(AppScreen.dispatch(user: current_user, verb: verb, path: params.require(:path), fields: fields, request: request))
      end

      def bridge
        to = params.require(:to).to_s
        to = "/" unless to.match?(%r{\Ahttps?://}) || (to.start_with?("/") && !to.start_with?("//"))
        render_data({ url: "#{request.base_url}/entrar/ponte?t=#{CGI.escape(AppScreen.bridge_token(current_user, to))}" })
      end

      private

      def respond_with(result) = render_data(result.except(:status), meta: { status: result[:status] })
    end
  end
end
