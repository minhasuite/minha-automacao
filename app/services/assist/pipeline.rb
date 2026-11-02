module Assist
  # Pipeline do Assist (ondaB1, B5): [palavra de ativação →] STT → intenção
  # (ou IA) → TTS, com os motores do AssistPipeline do local, e o registro da
  # execução (AssistRun) com o tempo de cada etapa para a tela de depuração.
  # Sem pipeline: o motor da instalação, o agente local e o idioma do local.
  module Pipeline
    module_function

    # → hash do Assist.call + "run_id" (+ "audio" com os bytes da fala, se `keep_audio`).
    # Levanta ArgumentError (sem texto) e Ai::Client::Error (STT), como antes.
    def run(site:, user:, text: nil, audio: nil, media_type: nil, speak: false, pipeline: nil, satellite: nil, source: "web",
            conversation_id: nil, keep_audio: false)
      pipeline ||= satellite&.pipeline || AssistPipeline.for(site)
      stages = []
      started = clock
      lang = Assist.language(pipeline&.language || site.language.presence)
      run = AssistRun.new(site: site, user: user, pipeline: pipeline, satellite_id: satellite&.id, source: source, language: lang)
      if audio
        engine = pipeline&.engine(:stt) || Engines::Installation
        text = stage(stages, "stt", engine) { engine.transcribe(pipeline&.stt.to_h, site: site, audio: audio, media_type: media_type.to_s, language: lang) }
        stages.last["text"] = text
      end
      out = stage(stages, "intent", nil) do
        Assist.call(site: site, user: user, text: text, language: lang, satellite: satellite, agent: pipeline&.agent || "local",
                    llm_provider: pipeline&.llm_provider, conversation_id: conversation_id)
      end
      stages.last.merge!("intent" => out["intent"], "slots" => out["slots"])
      if speak && out["text"].present?
        engine = pipeline&.engine(:tts) || Engines::Installation
        voice = begin
          stage(stages, "tts", engine) { engine.speak(pipeline&.tts.to_h, site: site, text: out["text"], language: lang) }
        rescue Ai::Client::Error => e
          Rails.logger.info("[assist] sem fala: #{e.message}")
          nil
        end
        if voice
          out["audio_url"] = Ai::Audio.store(voice[:data], voice[:media_type], "assistente-#{Time.current.to_i}").last
          out["audio"] = voice if keep_audio
        end
      end
      out.merge("run_id" => save(run, stages, started, heard: out["heard"], intent: out["intent"], reply: out["text"]).id)
    rescue ArgumentError, Ai::Client::Error => e
      save(run, stages, started, error: e.message.truncate(200)) if run
      raise
    end

    def stage(stages, name, engine)
      t = clock
      stages << { "stage" => name, "engine" => engine&.key }.compact
      result = yield
      stages.last["ms"] = ((clock - t) * 1000).round
      result
    rescue StandardError => e
      stages.last.merge!("ms" => ((clock - t) * 1000).round, "error" => e.message.truncate(200))
      raise
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
