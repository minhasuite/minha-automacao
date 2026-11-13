module Assist
  # Tempo de resposta da voz (voz-offline): mediana e p95 de cada etapa
  # (STT, intenção, TTS) e do total nas últimas execuções do local
  # (AssistRun guarda as 100 últimas), para a aba Testar e a Depuração.
  module Latency
    STAGES = %w[stt intent tts].freeze

    module_function

    # → {"stt" => {"n", "p50", "p95"}, ..., "total" => {...}} (só as etapas que aparecem).
    def for(site, limit: AssistRun::KEEP)
      runs = AssistRun.where(site: site, error: nil).order(created_at: :desc).limit(limit).pluck(:stages, :duration_ms)
      out = STAGES.index_with { |name| runs.flat_map { |stages, _| stages.select { |s| s["stage"] == name && s["error"].nil? }.map { |s| s["ms"].to_i } } }
      out["total"] = runs.filter_map(&:last)
      out.reject { |_k, v| v.empty? }.transform_values { |v| summary(v) }
    end

    def summary(values)
      sorted = values.sort
      { "n" => sorted.size, "p50" => pick(sorted, 0.5), "p95" => pick(sorted, 0.95) }
    end

    def pick(sorted, q) = sorted[((sorted.size - 1) * q).round]
  end
end
