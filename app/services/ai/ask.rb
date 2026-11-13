module Ai
  # "Perguntar à casa" (Lote 2, o `conversation.process` do HA): pergunta
  # livre sobre o estado atual, com os pontos do local (e o resumo das
  # últimas horas) como contexto. Só leitura: a IA não executa comando nem
  # vê nada além do texto do contexto. Usado pela tela /perguntar e pelo
  # assistente de voz (Assist) quando nenhuma intenção local reconhece a frase.
  module Ask
    SYSTEM = "Você é o assistente de uma instalação de automação (casa, loja ou fábrica). Responda em português do Brasil, " \
             "curto e direto, usando só o estado dos pontos informado abaixo. Se a informação não estiver lá, diga que não sabe. " \
             "Você não executa comandos: se pedirem para ligar ou desligar algo, explique que nesta fase só responde.".freeze
    HISTORY = 6.hours.to_i
    # Idioma da resposta = o da tela de quem pergunta.
    LANGUAGES = { "en" => "inglês (en)", "es" => "espanhol (es)" }.freeze

    module_function

    # → Ai::Request::Response (levanta Ai::Client::Error).
    # `provider`: a conta (voz-offline: o Assist escolhe a da rede da casa sem internet).
    def response(site:, question:, source: "pergunta", provider: nil)
      ctx = Automations::Context.new(site: site)
      Ai::Request.call(tenant: site.tenant, site: site, source: source, system: system, max_tokens: 800, timeout: 45, provider: provider,
                       prompt: "#{Ai::PointContext.text(ctx, history_s: HISTORY)}\n\nPergunta: #{question.to_s.strip.truncate(1_000)}")
    end

    def system
      lang = LANGUAGES[I18n.locale.to_s]
      lang ? SYSTEM.sub("português do Brasil", lang) : SYSTEM
    end

    # → só o texto da resposta.
    def call(...) = response(...).data.to_s
  end
end
