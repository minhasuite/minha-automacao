module Assist
  # Servidor MCP (ondaB1, B7; o `mcp_server` do HA): expõe a casa para LLMs
  # externos (Claude, ChatGPT, agentes) pelo Model Context Protocol, em
  # JSON-RPC 2.0 sobre HTTP (`POST /mcp`, transporte "streamable HTTP" sem
  # fluxo). As ferramentas são as intenções do Assist (Assist::Intent.tool) e
  # o `get_live_context` (estado dos pontos expostos), rodando com o papel x
  # risco da pessoa dona do token e só sobre o exposto ao Assist; crítico
  # nunca. Cada chamada fica na depuração do Assist (origem MCP).
  module Mcp
    PROTOCOL = "2025-06-18".freeze
    CONTEXT_TOOL = "get_live_context".freeze

    module_function

    # Mensagem (ou lote) JSON-RPC → resposta (nil para notificação).
    def handle(message, site:, user:)
      return message.filter_map { |m| handle(m, site: site, user: user) }.presence if message.is_a?(Array)
      return error(nil, -32_600, "Invalid Request") unless message.is_a?(Hash) && message["jsonrpc"] == "2.0" && message["method"].is_a?(String)

      id = message["id"]
      return nil if id.nil? && message["method"].start_with?("notifications/")

      result = dispatch(message["method"], message["params"].is_a?(Hash) ? message["params"] : {}, site, user)
      result ? { "jsonrpc" => "2.0", "id" => id, "result" => result } : error(id, -32_601, "Method not found")
    rescue ArgumentError => e
      error(id, -32_602, e.message)
    end

    def dispatch(method, params, site, user)
      case method
      when "initialize"
        { "protocolVersion" => params["protocolVersion"].presence || PROTOCOL, "capabilities" => { "tools" => { "listChanged" => false } },
          "serverInfo" => { "name" => "Minha Automação", "version" => "1" },
          "instructions" => "Casa #{site.name}: use get_live_context para ver o estado e as ferramentas para agir. Responda curto." }
      when "ping" then {}
      when "tools/list" then { "tools" => tools(site) }
      when "tools/call" then call(site, user, params["name"].to_s, params["arguments"].is_a?(Hash) ? params["arguments"] : {})
      when "resources/list" then { "resources" => [] }
      when "prompts/list" then { "prompts" => [] }
      end
    end

    def tools(_site)
      Llm.tools.map { |t| t.tool.then { |d| { "name" => d[:name], "description" => d[:description], "inputSchema" => d[:parameters].deep_stringify_keys } } } +
        [ { "name" => CONTEXT_TOOL, "description" => "Estado atual dos pontos expostos (nome, área, tipo, valor) e a hora local.",
            "inputSchema" => { "type" => "object", "properties" => {} } } ]
    end

    def call(site, user, name, args)
      lang = Assist.language(site.language.presence)
      I18n.with_locale(lang) do
        ctx = Ctx.new(site: site, user: user, role: site.role_for(user), heard: "#{name}(#{args.to_json})".first(300), language: lang)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        text, points, known = run(ctx, name, args)
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        AssistRun.create!(site: site, user: user, source: "mcp", language: lang, heard: ctx.heard, intent: name, reply: text.first(2000),
                          stages: [ { "stage" => "intent", "ms" => ms, "intent" => name, "slots" => args.transform_values(&:to_s) } ], duration_ms: ms)
        { "content" => [ { "type" => "text", "text" => text } ], "isError" => !known, "structuredContent" => { "points" => points.map(&:id) } }
      end
    end

    # → [texto, pontos, ferramenta conhecida?]
    def run(ctx, name, args)
      return [ Llm.context(ctx), [], true ] if name == CONTEXT_TOOL
      return [ *Llm.run_tool(ctx, name, args), true ] if Llm.tools.any? { |t| t.key == name }

      [ "ferramenta desconhecida: #{name}", [], false ]
    end

    def error(id, code, message) = { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
  end
end
