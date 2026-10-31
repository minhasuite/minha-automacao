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
      text = params[:text].to_s
      if (audio = params[:audio]).respond_to?(:read)
        return render(json: { error: "Áudio grande demais." }, status: :unprocessable_content) if audio.size > MAX_AUDIO

        text = Assist.transcribe(site: site, audio: audio.read, media_type: audio.content_type.to_s)
      end
      render json: Assist.call(site: site, user: current_user, text: text, speak: ActiveModel::Type::Boolean.new.cast(params[:speak]))
    rescue ArgumentError, Ai::Client::Error => e
      render json: { error: e.message }, status: :unprocessable_content
    end
  end
end
