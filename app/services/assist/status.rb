module Assist
  # Como a voz do local está agora (voz-offline): há internet? de onde vêm o
  # STT, a TTS e a IA do pipeline (local, nuvem ou nenhum)? A web (botão
  # Falar e a aba Testar) e o app mostram "modo offline" com isto.
  # `check: true` também pergunta aos servidores Wyoming da casa (describe,
  # com o tempo de resposta); sem `check`, nada sai do processo além da
  # verificação de internet (em cache).
  module Status
    module_function

    # → {"offline", "cloud", "stt" => {"mode", "provider"}, "tts" => {...}, "ai" => {"mode", "provider"}, "servers" => [...]?}
    def for(site, pipeline = AssistPipeline.for(site), check: false)
      cloud = pipeline.nil? || pipeline.cloud?
      out = { "offline" => Internet.offline?, "cloud" => cloud, "pipeline" => pipeline&.name,
              "stt" => voice(site, pipeline, :stt, cloud), "tts" => voice(site, pipeline, :tts, cloud), "ai" => ai(site, pipeline, cloud) }
      out["servers"] = servers(pipeline) if check
      out
    end

    # Modo de uma etapa de voz: "local", "cloud" ou "none" (e o provedor que atende).
    def voice(site, pipeline, kind, cloud)
      engine = pipeline&.engine(kind) || Engines::Auto
      return { "mode" => "local", "provider" => engine.key } if engine == Engines::WyomingServer

      if engine == Engines::Auto
        acc, where = Engines::Auto.accounts(site, kind, cloud: cloud).first
        return acc ? { "mode" => where.to_s, "provider" => acc.provider } : { "mode" => "none" }
      end

      acc = AiAccount.pick(pipeline.send(kind).to_h["provider"], default: Ai::Budget.for(site.tenant).default_provider, capability: kind)
      return { "mode" => "none" } unless acc
      return { "mode" => "local", "provider" => acc.provider } if acc.plugin.local?

      { "mode" => Internet.online? ? "cloud" : "none", "provider" => acc.provider }
    end

    # IA do "não entendi": "off" (agente só intenções), "local", "cloud" ou "none" (só as intenções agora).
    def ai(site, pipeline, cloud)
      agent = pipeline&.agent || "local"
      return { "mode" => "off" } if agent == "intents"

      key = Assist.ai_provider(site, pipeline&.llm_provider, structured: agent.include?("llm"), cloud: cloud)
      return { "mode" => "none" } unless key

      { "mode" => Ai.provider(key)&.local? ? "local" : "cloud", "provider" => key }
    end

    # Servidores Wyoming do pipeline e das contas locais: [{kind, host, port, ok, ms, detail}].
    def servers(pipeline)
      list = AiAccount.usable.select { |a| a.provider == "wyoming" }.flat_map { |a| a.client.servers.map { |kind, (host, port)| [ kind, host, port ] } }
      %i[stt tts wake].each do |kind|
        cfg = pipeline&.send(kind).to_h
        list << [ kind, cfg["host"], Engines::WyomingServer.port(cfg, kind) ] if cfg["engine"] == Engines::WyomingServer.key
      end
      list.uniq.map { |kind, host, port| ping(kind, host, port) }
    end

    def ping(kind, host, port)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      info = ::Wyoming.describe(host, port, timeout: 3)
      names = info.values_at("asr", "tts", "wake").flatten.compact.filter_map { |p| p["name"] if p.is_a?(Hash) }
      row(kind, host, port, t, true, names.join(", "))
    rescue Ai::Client::Error => e
      row(kind, host, port, t, false, e.message.truncate(120))
    end

    def row(kind, host, port, started, ok, detail)
      { "kind" => kind.to_s, "host" => host, "port" => port, "ok" => ok, "detail" => detail,
        "ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round }
    end
  end
end
