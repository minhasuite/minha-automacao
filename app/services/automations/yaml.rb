module Automations
  # Editor em YAML (ondaA1, A8; o "Editar em YAML" do HA): o rascunho em
  # YAML (a DSL daqui, pontos pela chave) e, colado, também o YAML de uma
  # automação ou script do HA, convertido na hora pelo importador
  # (Blueprints::HaImport) com as entidades viradas pontos (de-para da
  # importação ou a mesma chave) e os templates do HA aceitos (A9).
  module Yaml
    class Error < StandardError; end

    HA_BLOCK_KEYS = %w[trigger platform action service condition delay wait_template wait_for_trigger choose repeat sequence parallel].freeze

    module_function

    def dump(definition, site) = Dsl.with_keys(definition, site).to_yaml.delete_prefix("---\n")

    # Texto → [definição daqui, notas do que não converteu].
    def load(text, site, script: false)
      doc = YAML.safe_load(text.to_s, aliases: false)
      raise Error, "O YAML precisa ser um objeto (triggers, conditions, actions)." unless doc.is_a?(Hash)
      return [ doc, [] ] unless ha?(doc)

      bp = Blueprints::HaImport.new("", nil, entities: true).convert(Blueprints::HaImport.as_blueprint(script ? "script" : "automation", doc["alias"] || "YAML", doc))
      [ resolve(bp["definition"], bp["inputs"], site), bp["unsupported"] ]
    rescue Psych::Exception => e
      raise Error, "YAML inválido: #{e.message.truncate(160)}"
    rescue Blueprints::HaImport::Error => e
      raise Error, e.message
    end

    # É do HA: tem chave que a DSL daqui não usa ou bloco sem `type`.
    def ha?(doc)
      return true if (doc.keys - Dsl::KINDS.map(&:to_s)).any?

      Dsl::KINDS.any? { |k| Array(doc[k.to_s]).any? { |b| b.is_a?(Hash) && !b.key?("type") && b.keys.intersect?(HA_BLOCK_KEYS + %w[entity_id]) } }
    end

    # Entrada de ponto do importador ({"!input" => k}, "[[k]]") → chave do ponto daqui.
    def resolve(definition, inputs, site)
      refs = ExternalRef.map_for(site, HaTemplates::SOURCE, "Point")
      points = site.points.to_a
      by_id = points.index_by(&:id)
      by_key = points.index_by(&:key)
      keys = Array(inputs).to_h do |i|
        entity, cap = i["label"].to_s.split("#", 2)
        base = by_id[refs[entity]] || by_key[entity]
        base = points.find { |p| p.device_id == base.device_id && p.capability == cap } || base if base && cap
        [ i["key"], base&.key || entity ]
      end
      swap = lambda do |v|
        case v
        when Hash then v.keys == [ "!input" ] ? keys.fetch(v["!input"], v["!input"]) : v.transform_values(&swap)
        when Array then v.map(&swap)
        when String then v.gsub(/\[\[(\w+)\]\]/) { keys.fetch(::Regexp.last_match(1), ::Regexp.last_match(1)) }
        else v
        end
      end
      swap.call(definition)
    end
  end
end
