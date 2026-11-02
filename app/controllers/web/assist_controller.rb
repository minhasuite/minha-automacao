module Web
  # Assistente de voz (Pacote 3, Assist): o botão do microfone no painel
  # manda o áudio gravado (ou o texto digitado) e recebe a resposta em JSON
  # (texto + URL da fala, se houver TTS). Qualquer papel no local; o que a
  # voz comanda segue o papel x risco de quem fala (Assist).
  class AssistController < ApplicationController
    MAX_AUDIO = 10.megabytes

    def create
      site = Site.find(params[:site_id])
      authorize_site!(site, :view)
      audio = params[:audio] if params[:audio].respond_to?(:read)
      return render(json: { error: t("assist.too_big") }, status: :unprocessable_content) if audio && audio.size > MAX_AUDIO

      # ondaB1 (B5): pelo pipeline do local (ou o pedido), com o registro da execução.
      render json: Assist::Pipeline.run(site: site, user: current_user, text: params[:text].to_s, audio: audio&.read, media_type: audio&.content_type.to_s,
                                        speak: ActiveModel::Type::Boolean.new.cast(params[:speak]), pipeline: AssistPipeline.for(site, params[:pipeline_id]),
                                        conversation_id: params[:conversation_id].presence, source: "web")
    rescue ArgumentError, Ai::Client::Error => e
      render json: { error: e.message }, status: :unprocessable_content
    end
  end
end
