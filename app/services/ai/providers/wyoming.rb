module Ai
  module Providers
    # Voz local pelo protocolo Wyoming (o do HA): Whisper para transcrever e
    # Piper para falar, nos apps "Whisper" e "Piper" do catálogo ou em
    # qualquer servidor Wyoming da rede. Nada sai da casa e não há chave.
    #
    # Endereço: `tcp://host` (portas padrão: Whisper 10300, Piper 10200) ou
    # `tcp://host:porta-do-whisper?tts=porta-do-piper`. A conexão é TCP direta
    # (não é HTTP, por isso não passa pelo SafeHttp); só o dono configura.
    # Transcrever exige WAV PCM (o botão Falar e os satélites já mandam
    # assim); a fala volta em WAV.
    class Wyoming < Base
      describe key: "wyoming", local: true, label: "Voz local Wyoming (Whisper / Piper)", default_model: "whisper", models: %w[whisper],
               base_url: "tcp://localhost", custom_url: true, key_required: false,
               capabilities: %i[stt tts], stt_model: "whisper", tts_model: "piper", tts_voice: "pt_BR-faber-medium",
               hint: "Endereço tcp://IP-do-servidor (Whisper na 10300, Piper na 10200). Instale os apps Whisper e Piper em " \
                     "Configurações → Aplicativos e use Conectar. Voz em português, sem internet."
      texts en: { label: "Local Wyoming voice (Whisper / Piper)",
                  hint: "Address tcp://server-IP (Whisper on 10300, Piper on 10200). Install the Whisper and Piper apps in Settings → Apps " \
                        "and use Connect. Portuguese voice, no internet." },
            es: { label: "Voz local Wyoming (Whisper / Piper)",
                  hint: "Dirección tcp://IP-del-servidor (Whisper en 10300, Piper en 10200). Instala las apps Whisper y Piper en " \
                        "Configuración → Aplicaciones y usa Conectar. Voz en portugués, sin internet." }

      def transcribe(audio:, media_type:, model:, language:, timeout:) # rubocop:disable Lint/UnusedMethodArgument
        pcm, rate, width, channels = ::Wyoming.pcm_of(audio, media_type)
        text = ::Wyoming.transcribe(host, port(:stt), pcm, language: language, rate: rate, width: width, channels: channels, timeout: timeout)
        text.presence || raise(Ai::Client::Error, "Não entendi nada no áudio.")
      end

      def speak(text:, model:, voice:, timeout:) # rubocop:disable Lint/UnusedMethodArgument
        out = ::Wyoming.synthesize(host, port(:tts), text, voice: voice, timeout: timeout)
        { media_type: out[:media_type], data: out[:data] }
      end

      # voz-offline: onde estão o Whisper e o Piper ({stt: [host, porta], tts: [...]}), para a verificação da tela.
      def servers = { stt: [ host, port(:stt) ], tts: [ host, port(:tts) ] }

      private

      def uri = @uri ||= URI.parse(@base_url)
      def host = uri.host.presence || raise(Ai::Client::Error, "Endereço Wyoming inválido (use tcp://IP).")

      def port(kind)
        return uri.port || ::Wyoming::PORTS[:stt] if kind == :stt

        Integer(URI.decode_www_form(uri.query.to_s).to_h["tts"].to_s, exception: false) || ::Wyoming::PORTS[:tts]
      end
    end
  end
end
