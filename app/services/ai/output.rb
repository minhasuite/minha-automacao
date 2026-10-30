module Ai
  # Saída estruturada da ação "Pedir à IA": o usuário escreve um campo por
  # linha ("anomalia: sim/não Achou algo estranho?") ou cola um JSON schema
  # de objeto. Na DSL fica a lista [{name, type, description}] ou o schema.
  module Output
    TYPES = { "texto" => { type: "string" }, "numero" => { type: "number" }, "inteiro" => { type: "integer" },
              "sim/nao" => { type: "boolean" }, "lista" => { type: "array", items: { type: "string" } } }.freeze
    NAME = /\A[a-z_][a-z0-9_]{0,39}\z/
    LINE = %r{\A\s*([a-z_][a-z0-9_]*)\s*:\s*(texto|n[uú]mero|inteiro|sim/n[aã]o|lista)\b\s*(.*)\z}i

    module_function

    # Texto do formulário → valor da DSL (nil = texto livre). Linha que não
    # serve vira {"invalid" => linha} para a validação apontar.
    def parse(text)
      text = text.to_s.strip
      return nil if text.empty?
      return JSON.parse(text) if text.start_with?("{")

      text.lines.map(&:strip).compact_blank.map do |line|
        m = LINE.match(line) or next { "invalid" => line.truncate(60) }
        { "name" => m[1].downcase, "type" => I18n.transliterate(m[2].downcase), "description" => m[3].strip.presence }.compact
      end
    rescue JSON::ParserError
      [ { "invalid" => "JSON schema inválido" } ]
    end

    def error(value)
      if value.is_a?(Hash)
        return "o JSON schema precisa ser um objeto com properties" unless value["type"] == "object" && value["properties"].is_a?(Hash)
      elsif value.is_a?(Array) && value.any?
        bad = value.find { |f| !f.is_a?(Hash) || !NAME.match?(f["name"].to_s) || !TYPES.key?(f["type"]) }
        return "linha inválida \"#{bad.is_a?(Hash) ? bad['invalid'] || bad['name'] : bad}\" (use nome: texto|número|inteiro|sim/não|lista descrição)" if bad
        return "campo repetido" if value.pluck("name").uniq.size != value.size
      else
        return "use um campo por linha ou um JSON schema"
      end
      nil
    end

    def schema(value)
      return value if value.is_a?(Hash)
      return nil if value.blank?

      { type: "object", required: value.pluck("name"),
        properties: value.to_h { |f| [ f["name"], TYPES.fetch(f["type"]).merge(f["description"] ? { description: f["description"] } : {}) ] } }
    end

    def text(value)
      return JSON.pretty_generate(value) if value.is_a?(Hash)

      Array(value).map { |f| f["invalid"] || [ "#{f['name']}: #{f['type']}", f["description"] ].compact.join(" ") }.join("\n")
    end
  end
end
