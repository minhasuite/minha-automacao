module Assist
  # Pipeline do Assist (ondaB1, B5): [palavra de ativação →] STT → intenção
  # (ou IA) → TTS, com os motores do AssistPipeline do local, e o registro da
  # execução (AssistRun) com o tempo de cada etapa para a tela de depuração.
  # Sem pipeline ou sem motor escolhido: o motor Automático (voz da casa
  # primeiro, nuvem se houver internet; voz-offline), o agente local e o
  # idioma do local. `cloud: false` no pipeline = nada sai da casa.
  module Pipeline
    module_function

    # → hash do Assist.call + "run_id", "offline" e "stages" (+ "audio" com os bytes da fala, se `keep_audio`).
    # `execute: false` (teste da tela): só reconhece a intenção, não comanda nada.
    # Levanta ArgumentError (sem texto) e Ai::Client::Error (STT), como antes.
    def run(site:, user:, text: nil, audio: nil, media_type: nil, speak: false, pipeline: nil, satellite: nil, source: "web",
            conversation_id: nil, keep_audio: false, execute: true)
      pipeline ||= satellite&.pipeline || AssistPipeline.for(site)
      cloud = pipeline.nil? || pipeline.cloud?
      stages = []
      started = clock
      lang = Assist.language(pipeline&.language || site.language.presence)
      run = AssistRun.new(site: site, user: user, pipeline: pipeline, satellite_id: satellite&.id, source: source, language: lang)
      if audio
        engine = pipeline&.engine(:stt) || Engines::Auto
        text = stage(stages, "stt", engine) { engine.transcribe(cfg(pipeline, :stt, cloud), site: site, audio: audio, media_type: media_type.to_s, language: lang) }
        stages.last["text"] = text
      end
      out = stage(stages, "intent", nil) { execute ? understand_and_run(site, user, text, lang, satellite, pipeline, conversation_id, cloud) : dry(site, text, lang) }
      stages.last.merge!("intent" => out["intent"], "slots" => out["slots"])
      speak!(out, stages, pipeline, site, lang, cloud, keep_audio) if speak && out["text"].present?
      out.merge("run_id" => save(run, stages, started, heard: out["heard"], intent: out["intent"], reply: out["text"]).id,
                "offline" => Internet.offline?, "stages" => stages)
    rescue ArgumentError, Ai::Client::Error => e
      save(run, stages, started, error: e.message.truncate(200)) if run
      raise
    end

    def understand_and_run(site, user, text, lang, satellite, pipeline, conversation_id, cloud)
      Assist.call(site: site, user: user, text: text, language: lang, satellite: satellite, agent: pipeline&.agent || "local",
                  llm_provider: pipeline&.llm_provider, conversation_id: conversation_id, cloud: cloud)
    end

    # Teste sem executar: a intenção e os slots, e uma frase curta para medir a fala.
    def dry(site, text, lang)
      heard = text.to_s.squish.first(Assist::MAX_TEXT)
      raise ArgumentError, I18n.t("assist.empty") if heard.empty?

      I18n.with_locale(lang) do
        intent, slots = Assist.understand(site, heard, language: lang)
        say = intent ? I18n.t("assist.test.would", intent: intent.description) : I18n.t("assist.test.none")
        { "heard" => heard, "text" => say, "intent" => intent&.key || "unknown", "slots" => slots.to_h, "points" => [], "language" => lang, "dry_run" => true }
      end
    end

    def speak!(out, stages, pipeline, site, lang, cloud, keep_audio)
      engine = pipeline&.engine(:tts) || Engines::Auto
      voice = begin
        stage(stages, "tts", engine) { engine.speak(cfg(pipeline, :tts, cloud), site: site, text: out["text"], language: lang) }
      rescue Ai::Client::Error => e
        Rails.logger.info("[assist] sem fala: #{e.message}")
        nil
      end
      return unless voice

      out["audio_url"] = Ai::Audio.store(voice[:data], voice[:media_type], "assistente-#{Time.current.to_i}").last
      out["audio"] = voice if keep_audio
    end

    # Configuração do motor + se a nuvem vale (o Automático lê "cloud").
    def cfg(pipeline, kind, cloud) = pipeline&.send(kind).to_h.merge("cloud" => cloud)

    def stage(stages, name, engine)
      t = clock
      Engines.used = nil
      stages << { "stage" => name, "engine" => engine&.key }.compact
      result = yield
      stages.last["ms"] = ((clock - t) * 1000).round
      stages.last.merge!(Engines.used) if Engines.used
      result
    rescue StandardError => e
      stages.last.merge!("ms" => ((clock - t) * 1000).round, "error" => e.message.truncate(200))
      raise
    ensure
      Engines.used = nil
    end

    def save(run, stages, started, **attrs)
      run.assign_attributes(stages: stages, duration_ms: ((clock - started) * 1000).round, **attrs)
      run.heard = run.heard&.first(300)
      run.save!
      run
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
