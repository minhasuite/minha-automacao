module Ai
  module Providers
    # Gemini (`generateContent`, Net::HTTP direto). Traduz os blocos do formato
    # Anthropic (texto, imagem e PDF em base64) para `parts` com `inlineData`.
    # Saída estruturada por `responseJsonSchema`.
    #
    # Raciocínio: família 3.x usa `thinkingLevel` (não dá para desligar; sem
    # effort vai o mínimo que o modelo aceita); 2.5 usa `thinkingBudget`. O
    # pensamento sai do mesmo `maxOutputTokens`, então ele ganha folga.
    class Gemini < Base
      BUDGETS = { "low" => 1_024, "medium" => 8_192, "high" => 24_576 }.freeze

      describe key: "gemini", label: "Google Gemini", default_model: "gemini-3.5-flash",
               models: %w[gemini-3.5-flash gemini-3.5-flash-lite gemini-3.1-pro-preview gemini-2.5-flash],
               base_url: "https://generativelanguage.googleapis.com/v1beta/models", capabilities: %i[text image structured tools temperature stt tts],
               stt_model: "gemini-2.5-flash", tts_model: "gemini-2.5-flash-preview-tts", tts_voice: "Kore",
               hint: "Chave em aistudio.google.com → Get API key."
      texts en: { label: "Google Gemini", hint: "Get a key at aistudio.google.com → Get API key." },
            es: { label: "Google Gemini", hint: "Clave en aistudio.google.com → Get API key." }

      PCM_RATE = /rate=(\d+)/

      # Voz (Lote 5, G14): o áudio vai junto do pedido de transcrição.
      def transcribe(audio:, media_type:, model:, language:, timeout:)
        ask = "Transcreva o áudio#{" (idioma: #{language})" if language.present?}. Responda só com o texto falado, sem comentários."
        body = { contents: [ { role: "user", parts: [ { text: ask }, { inlineData: { mimeType: media_type, data: Base64.strict_encode64(audio) } } ] } ] }
        json = post_json("#{@base_url}/#{model}:generateContent", body, { "x-goog-api-key" => @api_key.to_s }, timeout)
        Array(json.dig("candidates", 0, "content", "parts")).filter_map { |p| p["text"] }.join.strip.presence ||
          raise(Ai::Client::Error, "Não entendi nada no áudio.")
      end

      # O modelo de fala devolve PCM 16 bits mono; vira WAV.
      def speak(text:, model:, voice:, timeout:)
        body = { contents: [ { parts: [ { text: text } ] } ],
                 generationConfig: { responseModalities: [ "AUDIO" ], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } } } }
        json = post_json("#{@base_url}/#{model}:generateContent", body, { "x-goog-api-key" => @api_key.to_s }, timeout)
        inline = json.dig("candidates", 0, "content", "parts", 0, "inlineData") or raise Ai::Client::Error, "A IA não devolveu áudio. Tente de novo."
        pcm = Base64.decode64(inline["data"].to_s)
        rate = inline["mimeType"].to_s[PCM_RATE, 1]&.to_i || 24_000
        { media_type: "audio/wav", data: wav(pcm, rate) }
      end

      def complete(model:, system:, user:, schema:, max_tokens:, timeout:, effort: nil, temperature: nil)
        thinking, headroom = thinking_config(model.to_s, effort.presence)
        config = { maxOutputTokens: max_tokens + headroom, thinkingConfig: thinking }
        config.merge!(responseMimeType: "application/json", responseJsonSchema: schema) if schema
        config[:temperature] = temperature unless temperature.nil?
        body = { systemInstruction: { parts: [ { text: system } ] }, contents: [ { role: "user", parts: parts(user) } ], generationConfig: config }
        json = post_json("#{@base_url}/#{model}:generateContent", body, { "x-goog-api-key" => @api_key.to_s }, timeout)
        candidate = json.dig("candidates", 0)
        text = Array(candidate&.dig("content", "parts")).reject { |p| p["thought"] }.filter_map { |p| p["text"] }.join
        Rails.logger.warn("[ai] gemini sem texto: finish=#{candidate&.dig('finishReason')} block=#{json.dig('promptFeedback', 'blockReason')}") if text.blank?
        meta = json["usageMetadata"] || {}
        # Pensamento é cobrado como saída.
        result(text, schema, meta["promptTokenCount"], meta["candidatesTokenCount"].to_i + meta["thoughtsTokenCount"].to_i)
      end

      private

      def wav(pcm, rate) = [ "RIFF", 36 + pcm.bytesize, "WAVE", "fmt ", 16, 1, 1, rate, rate * 2, 2, 16, "data", pcm.bytesize ].pack("a4Va4a4VvvVVvva4V") + pcm

      def thinking_config(model, effort)
        level = effort && (BUDGETS.key?(effort) ? effort : "high")
        if model.start_with?("gemini-2")
          budget = level ? BUDGETS[level] : (model.include?("pro") ? 128 : 0) # o Pro não desliga
          [ { thinkingBudget: budget }, budget ]
        else
          level ||= model.include?("pro") ? "low" : "minimal" # o Pro não tem minimal
          [ { thinkingLevel: level }, BUDGETS.fetch(level, 0) ]
        end
      end

      def parts(user)
        blocks(user).map do |b|
          if b[:type].to_s == "text" then { text: b[:text].to_s }
          else { inlineData: { mimeType: b.dig(:source, :media_type) || "application/pdf", data: b.dig(:source, :data) } }
          end
        end
      end
    end
  end
end
