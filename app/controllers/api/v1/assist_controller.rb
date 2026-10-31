module Api
  module V1
    # Assistente de voz (Pacote 3, Assist): `text` ou `audio` (multipart,
    # transcrito pelo STT da instalação) → intenção local ou "Perguntar à
    # casa". `speak=true` devolve também a fala (URL assinada, 1 dia).
    # Só token do app (comando por voz é da pessoa, não de chave).
    class AssistController < BaseController
      MAX_AUDIO = 10.megabytes

      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        text = params[:text].to_s
        if (audio = params[:audio]).respond_to?(:read)
          return render_error(:invalid_parameter, "Áudio grande demais (até 10 MB).", status: :unprocessable_content) if audio.size > MAX_AUDIO

          text = Assist.transcribe(site: site, audio: audio.read, media_type: audio.content_type.to_s)
        end
        render_data(Assist.call(site: site, user: current_user, text: text, speak: bool(params[:speak])))
      rescue ArgumentError => e
        render_error(:invalid_parameter, e.message, status: :unprocessable_content)
      rescue Ai::Client::Error => e
        render_error(:ai_unavailable, e.message.truncate(200), status: :service_unavailable)
      end
    end
  end
end
