# IA como plugins (Lote 2), no padrão de Integrations::PLUGINS e
# HelperTypes::PLUGINS: cada provedor é uma classe em app/services/ai/providers/
# (subclasse de Ai::Providers::Base) registrada em PROVIDERS. Ela se descreve
# (chave, rótulo, modelo padrão, capacidades) e implementa `complete`. A tela
# de Configurações → IA, a ação "Pedir à IA", o "Perguntar à casa" e a IA da
# suíte (Ai::Client, chave em env) perguntam ao registro; nenhum deles tem
# `case` por provedor. Provedor novo = classe + nome aqui + spec.
module Ai
  PROVIDERS = %w[Anthropic Openai Gemini Ollama LocalAudio].freeze

  # O que um provedor pode declarar em `capabilities`.
  CAPABILITIES = { text: "Texto", image: "Imagem na entrada", structured: "Saída estruturada (JSON schema)",
                   tools: "Ferramentas", temperature: "Temperatura", stt: "Voz para texto", tts: "Texto para fala" }.freeze

  module_function

  def providers = PROVIDERS.map { |name| Providers.const_get(name) }
  def provider(key) = providers.find { |p| p.key == key.to_s }
  # Provedores (que têm a capacidade, se pedida) → {chave => rótulo}.
  def choices(capability = nil) = providers.select { |p| capability.nil? || p.supports?(capability) }.to_h { |p| [ p.key, p.label ] }
end
