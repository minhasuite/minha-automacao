module Ai
  # Voz da instalação (Lote 5, G14): transcrever áudio (STT) e gerar fala
  # (TTS) com o provedor que declara a capacidade (`stt`/`tts` em
  # Ai::PROVIDERS: OpenAI, Gemini, Voz local). Mesma conta, limite mensal e
  # registro (AiCall, sem o áudio nem o texto) da IA de texto.
  module Audio
    Result = Data.define(:data, :provider, :model)
    MAX_BYTES = 20.megabytes
    TTL = 1.day
    EXTENSIONS = { "audio/mpeg" => ".mp3", "audio/mp4" => ".m4a", "audio/wav" => ".wav", "audio/x-wav" => ".wav", "audio/webm" => ".webm",
                   "audio/ogg" => ".ogg", "video/webm" => ".webm" }.freeze

    module_function

    def extension(media_type) = EXTENSIONS.fetch(media_type.to_s.split(";").first, ".bin")

    def transcribe(tenant:, audio:, media_type:, language: "pt", provider: nil, model: nil, site: nil, automation: nil, source: "automacao")
      raise Ai::Client::Error, "Áudio grande demais (até 20 MB)." if audio.bytesize > MAX_BYTES

      call(:stt, tenant, provider, model, site, automation, source) do |client, m|
        client.transcribe(audio: audio, media_type: media_type, model: m, language: language, timeout: 120)
      end
    end

    def speak(tenant:, text:, voice: nil, provider: nil, model: nil, site: nil, automation: nil, source: "automacao")
      call(:tts, tenant, provider, model, site, automation, source) do |client, m, plugin|
        client.speak(text: text.to_s.truncate(4000), model: m, voice: voice.presence || plugin.tts_voice, timeout: 60)
      end
    end

    # Conta com a capacidade, limite do mês e registro da chamada (ok, erro ou bloqueada).
    def call(capability, tenant, provider, model, site, automation, source)
      budget = Ai::Budget.for(tenant)
      account = AiAccount.pick(provider, default: budget.default_provider, capability: capability) or
        raise Ai::Client::Error, I18n.t("ai_settings.no_provider", what: I18n.t("ai_settings.caps.#{capability}").downcase)
      plugin = account.plugin
      model = model.presence || (account.model.presence if capability == :stt && !plugin.supports?(:text)) || plugin.public_send(:"#{capability}_model")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      log = lambda do |status, error = nil|
        AiCall.create!(source: source, site: site, automation: automation, provider: plugin.key, model: model, status: status, error: error&.truncate(200),
                       duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end
      begin
        budget.check!
        data = yield(account.client, model, plugin)
      rescue Ai::Client::Error => e
        log.call(e.is_a?(Ai::Request::LimitReached) ? "blocked" : "error", e.message)
        raise
      end
      log.call("ok")
      Result.new(data: data, provider: plugin.key, model: model)
    end

    # Áudio por URL https (SafeHttp) ou anexo do sistema (/rails/active_storage/...): [bytes, tipo].
    def fetch(url)
      if (m = Ai::Images::BLOB.match(url))
        blob = ActiveStorage::Blob.find_signed(m[1]) or raise ArgumentError, "anexo não encontrado"
        return [ blob.download, blob.content_type ]
      end

      res = SafeHttp.get(url, timeout: 30)
      raise ArgumentError, "respondeu #{res.status}" if res.status >= 400

      [ res.body.to_s, Array(res.headers["content-type"]).first.to_s.split(";").first.presence || "application/octet-stream" ]
    end

    # Fala guardada como anexo, com URL assinada que expira; o anexo some depois.
    def store(bytes, media_type, name)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "#{name}#{extension(media_type)}", content_type: media_type)
      ActiveStorage::PurgeJob.set(wait: TTL).perform_later(blob)
      [ blob, Rails.application.routes.url_helpers.rails_service_blob_path(blob.signed_id(expires_in: TTL), blob.filename.to_s) ]
    end
  end
end
