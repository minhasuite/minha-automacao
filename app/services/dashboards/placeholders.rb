module Dashboards
  # Marcadores `{{ <espaço>.<chave> }}` dentro de um JSON de painel ou de modelo
  # (P1.3 e P2.2 da proposta de personalização): `{{ vars.area }}` no modelo de
  # card, `{{ fields.rede }}` na predefinição de painel. Não é Liquid: é só
  # troca de dado por dado antes de validar pelo Schema.
  #
  # - Texto que é só o marcador vira o valor (lista, número, id), sem passar a texto.
  # - Marcador no meio do texto vira o valor em texto.
  # - Valor vazio (nil/""/[]) some: chave de objeto sai, item de lista sai; lista
  #   dentro de lista é aberta (`"binds": ["{{ fields.luzes }}", "{{ fields.abajur }}"]`).
  #
  # `{{ vars.area.name }}` (com caminho) é do Liquid do modelo e fica como está
  # nos espaços de texto; nos de dado, quem chama decide pelo `lookup`.
  module Placeholders
    NAME = /[a-z0-9_]+(?:\.[a-z0-9_]+)*/

    module_function

    def pattern(ns) = /\{\{\s*#{Regexp.escape(ns)}\.(#{NAME})\s*\}\}/
    def exact(ns) = /\A\s*\{\{\s*#{Regexp.escape(ns)}\.(#{NAME})\s*\}\}\s*\z/

    # Troca os marcadores de `ns` pelo que o bloco devolver para o caminho ("rede", "area.link").
    def fill(obj, ns, &lookup)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          v = fill(v, ns, &lookup)
          h[k] = v unless empty?(v)
        end
      when Array
        obj.flat_map do |v|
          was_marker = v.is_a?(String) && v.match?(exact(ns))
          v = fill(v, ns, &lookup)
          was_marker && v.is_a?(Array) ? v : [ v ]
        end.reject { |v| empty?(v) }
      when String
        if (m = obj.match(exact(ns)))
          lookup.call(m[1])
        else
          obj.gsub(pattern(ns)) { lookup.call(Regexp.last_match(1)).to_s }
        end
      else obj
      end
    end

    # Primeira parte de cada marcador usado ("rede", "area"), sem repetir.
    def names(obj, ns)
      case obj
      when Hash then obj.values.flat_map { |v| names(v, ns) }.uniq
      when Array then obj.flat_map { |v| names(v, ns) }.uniq
      when String then obj.scan(pattern(ns)).map { |(path)| path.split(".").first }.uniq
      else []
      end
    end

    def empty?(v) = v.nil? || v == "" || v == [] || v == {}
  end
end
