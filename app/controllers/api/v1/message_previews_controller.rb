module Api
  module V1
    # Prévia de um texto de aviso (P3, `MessageTemplate`): o mesmo Liquid do
    # Texto do painel e das automações, com o ponto escolhido como gatilho.
    #   POST /sites/:site_id/message_preview {template, point_id?} → {text}
    # Técnico ou dono do local (quem cadastra avisos e alertas).
    class MessagePreviewsController < BaseController
      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :manage)
        point = site.points.find(params[:point_id]) if params[:point_id].present?
        trigger = point ? MessageTemplate.point_trigger(point, minutes: 0) : {}
        text, error = MessageTemplate.preview(site, params.require(:template).to_s.first(MessageTemplate::MAX * 2), trigger: trigger)
        return render_error(:invalid_template, error, status: :unprocessable_content) if error

        render_data({ text: text })
      end
    end
  end
end
