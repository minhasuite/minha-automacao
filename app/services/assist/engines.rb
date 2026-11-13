module Assist
  # Motores de voz dos pipelines (ondaB1, B5/B6): STT, TTS e palavra de
  # ativação como plugins. Motor novo = subclasse de Engines::Base em
  # assist/engines/<nome>.rb + nome em PLUGINS; o pipeline e a tela só
  # perguntam ao registro:
  #   describe key:, label:, kinds: %i[stt tts wake], fields: [[nome, :text|:number|:provider_stt|:provider_tts]]
  #   transcribe(cfg, site:, audio:, media_type:, language:) → texto
  #   speak(cfg, site:, text:, language:) → {data: bytes, media_type:}
  #   detect(cfg, site:, audio:, media_type:) → nome da palavra ou nil
  #   check(cfg, kind) → mensagens de erro da configuração
  module Engines
    PLUGINS = %w[Auto Installation WyomingServer].freeze

    module_function

    def plugins = PLUGINS.map { |n| const_get(n) }
    def [](key) = plugins.find { |p| p.key == key.to_s }
    def for(kind) = plugins.select { |p| p.kinds.include?(kind.to_sym) }

    # voz-offline: qual conta o motor usou na última chamada desta thread
    # ({provider, where: local|cloud}); o pipeline lê e zera a cada etapa.
    def used = Thread.current[:assist_engine_used]
    def used=(info)
      Thread.current[:assist_engine_used] = info
    end
  end
end
