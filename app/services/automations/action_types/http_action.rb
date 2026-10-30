module Automations
  module ActionTypes
    # "Chamar HTTP / webhook" (F9): avisa outro sistema (minhas-vendas, meu-gestor,
    # um webhook qualquer). URL, cabeçalhos e corpo são textos Liquid; o
    # segredo fica cifrado na definição e entra como `{{ secret }}`. Saída
    # pelo SafeHttp (endereço interno bloqueado, redirect checado de novo).
    # A resposta vira as variáveis `http_status` e `http_body` (até 1000
    # caracteres) e, com `response_variable` (Lote 1), {status, body, json}.
    class HttpAction < Base
      METHODS = SafeHttp::METHODS.index_by(&:itself).freeze

      describe key: "http", label: "Chamar HTTP / webhook", defaults: { "method" => "POST", "timeout" => 10 },
               fields: [ f("method", :select, "Método", required: true, options: METHODS), f("url", :template, "URL", required: true),
                         f("headers", :template, "Cabeçalhos (um por linha, Nome: valor)"), f("secret", :secret, "Segredo (cifrado; use {{ secret }})"),
                         f("body", :template, "Corpo"), f("timeout", :number, "Tempo limite (s)") ]
      returns "{status, body, json}"

      def self.rules(node)
        node["timeout"].nil? || (node["timeout"].is_a?(::Numeric) && node["timeout"].between?(1, 30)) ? [] : [ "tempo limite de 1 a 30 segundos." ]
      end

      def self.call(e, _path, node)
        method = node["method"] || "POST"
        out = with_secret(e, node) do
          { url: e.ctx.render(node["url"]).strip, body: (e.ctx.render(node["body"]) if node["body"].present?),
            headers: headers(e.ctx.render(node["headers"])) }
        end
        host = host_of(out[:url])
        title = "Chamar #{method} #{host}"
        return [ title, "simulated", "Não enviado (simulação)." ] if e.dry_run?

        res = SafeHttp.request(method, out[:url], headers: out[:headers], body: out[:body], timeout: (node["timeout"] || 10).to_i)
        e.ctx.vars["http_status"] = res.status
        e.ctx.vars["http_body"] = res.body.to_s.force_encoding("UTF-8").scrub.truncate(1000)
        respond(e, node, response_value(res))
        raise Engine::Failure, "#{host} respondeu #{res.status}." if res.status >= 400

        [ title, "ok", "Resposta #{res.status}" ]
      rescue SafeHttp::Error => ex
        raise Engine::Failure, ex.message
      end

      # {status, body, json} (json só quando o corpo é JSON).
      def self.response_value(res)
        body = res.body.to_s.dup.force_encoding("UTF-8").scrub
        json = JSON.parse(body) if body.size <= 10_000 && body.lstrip.start_with?("{", "[")
        { "status" => res.status, "body" => body.truncate(1000), "json" => json }.compact
      rescue JSON::ParserError
        { "status" => res.status, "body" => body.truncate(1000) }
      end

      # Só o host vai para o trace (a URL pode levar o segredo).
      def self.host_of(url)
        URI.parse(url).host || "?"
      rescue URI::InvalidURIError
        "?"
      end

      # "Nome: valor" por linha → hash (linha sem ":" é ignorada).
      def self.headers(text)
        text.to_s.lines.filter_map { |l| k, v = l.split(":", 2); [ k.strip, v.strip ] if v && k.strip.match?(/\A[\w-]+\z/) }.to_h
      end

      # O segredo só existe durante a montagem dos textos (nunca no trace).
      def self.with_secret(e, node)
        e.ctx.vars["secret"] = Dsl.decrypt_secret(node["secret"]).to_s
        yield
      ensure
        e.ctx.vars.delete("secret")
      end
    end
  end
end
