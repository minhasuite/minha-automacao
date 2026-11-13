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
        audio = params[:audio] if params[:audio].respond_to?(:read)
        return render_error(:invalid_parameter, "Áudio grande demais (até 10 MB).", status: :unprocessable_content) if audio && audio.size > MAX_AUDIO

        # ondaB1 (B5): pelo pipeline do local (ou `pipeline_id`), com o registro da execução.
        render_data(Assist::Pipeline.run(site: site, user: current_user, text: params[:text].to_s, audio: audio&.read, media_type: audio&.content_type.to_s,
                                         speak: bool(params[:speak]), pipeline: AssistPipeline.for(site, params[:pipeline_id]),
                                         conversation_id: params[:conversation_id].presence, source: "app"))
      rescue ArgumentError => e
        render_error(:invalid_parameter, e.message, status: :unprocessable_content)
      rescue Ai::Client::Error => e
        render_error(:ai_unavailable, e.message.truncate(200), status: :service_unavailable)
      end

      # voz-offline: modo offline e de onde vêm STT, TTS e IA agora (o app mostra "modo offline").
      def status
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        render_data(Assist::Status.for(site, AssistPipeline.for(site, params[:pipeline_id])))
      end

      # appweb2 (D5): pipelines do local para o app escolher, e se cada um ouve
      # a palavra de ativação (motor `wake` configurado).
      def pipelines
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        render_data(AssistPipeline.where(site: site).order(:created_at).map do |p|
          { id: p.id, name: p.name, preferred: p.preferred?, language: p.language, wake: p.engine(:wake).present?, wake_names: p.wake.to_h["names"].to_s.split(/[,\s]+/).compact_blank }
        end)
      end

      # POST /sites/:id/assist/wake {audio (WAV 16 kHz), pipeline_id?} → {detected, name}
      # O celular manda pedaços curtos enquanto "ouvir a palavra" está ligado;
      # quem detecta é o motor de ativação do pipeline (Wyoming/openWakeWord).
      def wake
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        audio = params[:audio] if params[:audio].respond_to?(:read)
        return render_error(:invalid_parameter, "Mande o áudio (WAV, até 1 MB).", status: :unprocessable_content) if audio.nil? || audio.size > 1.megabyte

        pipeline = AssistPipeline.for(site, params[:pipeline_id])
        engine = pipeline&.engine(:wake)
        return render_error(:wake_unavailable, I18n.t("appweb.wake_unavailable"), status: :unprocessable_content) unless engine.respond_to?(:detect)

        name = engine.detect(pipeline.wake, audio: audio.read, media_type: audio.content_type.to_s)
        render_data({ detected: name.present?, name: name })
      rescue ::Wyoming::Error => e
        render_error(:wake_unavailable, e.message.truncate(200), status: :service_unavailable)
      end
    end
  end
end
