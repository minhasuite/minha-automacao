module Ai
  module Providers
    # Voz no formato da OpenAI (Lote 5, G14): `/audio/transcriptions`
    # (multipart) e `/audio/speech` (JSON → MP3). A OpenAI e os servidores
    # locais compatíveis (faster-whisper-server/speaches, openedai-speech com
    # Piper) usam o mesmo caminho; tudo passa pelo SafeHttp (a URL do local é
    # digitada pelo usuário: o IP da LAN precisa estar em Saída HTTP).
    module OpenaiAudio
      def transcribe(audio:, media_type:, model:, language:, timeout:)
        boundary = "ma#{SecureRandom.hex(12)}"
        fields = { "model" => model, "language" => language.presence, "response_format" => "json" }.compact
        body = fields.map { |k, v| "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n" }.join.b +
               "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio#{Ai::Audio.extension(media_type)}\"\r\n".b +
               "Content-Type: #{media_type}\r\n\r\n".b + audio.b + "\r\n--#{boundary}--\r\n".b
        json = JSON.parse(audio_post("/audio/transcriptions", body, "multipart/form-data; boundary=#{boundary}", timeout))
        json["text"].to_s.strip.presence || raise(Ai::Client::Error, "Não entendi nada no áudio.")
      rescue JSON::ParserError
        raise Ai::Client::Error, "O serviço de voz respondeu num formato inesperado."
      end

      def speak(text:, model:, voice:, timeout:)
        body = { model: model, input: text, voice: voice, response_format: "mp3" }.to_json
        { media_type: "audio/mpeg", data: audio_post("/audio/speech", body, "application/json", timeout) }
      end

      private

      def audio_post(path, body, content_type, timeout)
        headers = { "Content-Type" => content_type }
        headers["Authorization"] = "Bearer #{@api_key}" if @api_key.present?
        res = SafeHttp.request("POST", "#{@base_url}#{path}", headers: headers, body: body, timeout: timeout)
        http_error!(res.status, res.body) if res.status >= 400
        res.body.to_s
      rescue SafeHttp::Error => e
        raise Ai::Client::TransientError, "Voz: #{e.message}"
      end
    end
  end
end
