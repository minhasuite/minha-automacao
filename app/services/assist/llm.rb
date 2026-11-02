module Assist
  # IA que controla a casa (ondaB1, B4; o "LLM com Assist API" do HA). Serve
  # a qualquer provedor de Ai::PROVIDERS com saída estruturada, sem API de
  # ferramentas própria de cada um: o modelo devolve {say, calls:[{tool,
  # args}]}, o MA roda cada chamada pela intenção de mesmo nome (a ferramenta
  # é a intenção: Assist::Intent.tool) com o papel x risco de quem fala, e
  # devolve os resultados ao modelo, até ROUNDS voltas. O modelo vê só os
  # pontos expostos ao Assist (tela Expor), nunca chave nem histórico bruto.
  # A conversa continua por `conversation_id` (as últimas falas em cache).
  module Llm
    ROUNDS = 3
    HISTORY = 6
    TTL = 5.minutes
    MAX_CONTEXT = 120

    SCHEMA = {
      type: "object", required: %w[say calls],
      properties: {
        say: { type: "string", description: "Resposta curta para a pessoa (vazia se ainda vai chamar ferramentas)." },
        calls: { type: "array", items: { type: "object", required: %w[tool args],
                                         properties: { tool: { type: "string" }, args: { type: "string", description: "Argumentos em JSON" } } } }
      }
    }.freeze

    LANGUAGES = { "pt-BR" => "português do Brasil", "en" => "inglês", "es" => "espanhol" }.freeze

    module_function

    def tools = Assist.intents.select { |i| i.respond_to?(:tool?) && i.tool? }

    # → Reply (intenção "llm"; erro da IA vira o texto de "não entendi").
    def call(ctx, heard, provider: nil, conversation_id: nil)
      history = conversation_id ? Rails.cache.read(cache_key(ctx, conversation_id)).to_a : []
      turns = history + [ "Pessoa: #{heard}" ]
      touched = []
      say = nil
      ROUNDS.times do |round|
        res = Ai::Request.call(tenant: ctx.site.tenant, site: ctx.site, source: "voz", system: system(ctx), prompt: turns.join("\n"),
                               schema: SCHEMA, provider: provider, max_tokens: 800, timeout: 45).data.to_h.with_indifferent_access
        calls = Array(res[:calls]).first(5)
        say = res[:say].to_s.squish
        break if calls.empty? || round == ROUNDS - 1

        calls.each do |c|
          out, points = run_tool(ctx, c[:tool].to_s, c[:args])
          touched.concat(points)
          turns << "Ferramenta #{c[:tool]}(#{c[:args]}): #{out}"
        end
      end
      remember(ctx, conversation_id, turns + [ "Assistente: #{say}" ])
      Reply.new(text: say, intent: "llm", points: touched.uniq)
    rescue Ai::Client::Error => e
      Reply.new(text: Intent.text(:unknown, error: e.message.truncate(80)), intent: "unknown")
    end

    # Uma chamada de ferramenta: a intenção com os argumentos como slots. → [texto, pontos]
    def run_tool(ctx, name, raw_args)
      intent = tools.find { |i| i.key == name } or return [ "ferramenta desconhecida", [] ]
      args = raw_args.is_a?(Hash) ? raw_args : JSON.parse(raw_args.to_s.presence || "{}")
      slots = args.to_h.slice(*intent.slots).transform_values(&:to_s)
      r = intent.handle(ctx, slots)
      r ? [ r.text.presence || "ok", r.points ] : [ "nada encontrado com esses argumentos", [] ]
    rescue JSON::ParserError
      [ "argumentos inválidos (JSON)", [] ]
    end

    def system(ctx)
      lines = Assist.exposed(ctx.site.points).first(MAX_CONTEXT).map do |p|
        area = p.area || p.device&.area
        "- #{p.display_names.compact.join(' ')}#{" (#{area.name})" if area} [#{p.capability}]: #{p.quality == 'good' ? Assist.value_text(p) : '?'}"
      end
      catalog = tools.map { |t| "- #{t.key}(#{t.slots.join(', ')}): #{t.description}" }
      <<~TXT
        Você é o assistente de voz de #{ctx.site.name}. Responda em #{LANGUAGES.fetch(ctx.language)}, curto (uma ou duas frases), sem markdown.
        Para agir na casa, chame ferramentas em "calls" (args em JSON com os parâmetros dela) e deixe "say" vazio; depois dos
        resultados, responda em "say" com "calls" vazio. Use os nomes como aparecem abaixo. Se a ferramenta recusar
        (permissão ou risco), explique; nunca invente estado. Hora local: #{I18n.l(Time.current, format: '%d/%m/%Y %H:%M')}.
        #{"A pessoa está em #{ctx.area.name}." if ctx.area}
        Ferramentas:
        #{catalog.join("\n")}
        Pontos expostos:
        #{lines.join("\n").presence || '- nenhum'}
      TXT
    end

    def cache_key(ctx, id) = "assist:conv:#{ctx.site.id}:#{ctx.user&.id}:#{id}"

    def remember(ctx, id, turns)
      Rails.cache.write(cache_key(ctx, id), turns.last(HISTORY * 2), expires_in: TTL) if id
    end
  end
end
