module Search
  # Quanto um texto bate com os termos da busca (todos precisam bater), sem
  # acento e sem caixa: palavra igual 3, começo de palavra 2, dentro de palavra 1,
  # quase igual 0,5 (erro de digitação: uma letra trocada, sobrando, faltando ou
  # duas invertidas; duas em termo de 7+ letras; termo de 4+ letras). O primeiro
  # texto é o título e vale 1,5x. nil = algum termo não bateu.
  #
  # Por que aqui e não pg_trgm/unaccent no Postgres: as fontes juntam texto de
  # várias tabelas (ponto + aparelho + área + apelidos, widget dentro do JSON do
  # painel, páginas do i18n) e os pontos já estão na memória
  # (`Dashboards::Cache.points`); a casa tem centenas de itens, não milhões.
  module Match
    module_function

    def score(terms, *texts)
      return 0 if terms.empty?

      title, *rest = texts
      t = prepare(title)
      r = prepare(rest.compact.join(" "))
      terms.sum do |term|
        best = [ term_score(term, *t)&.*(1.5), term_score(term, *r) ].compact.max or return nil
        best
      end
    end

    def prepare(text)
      hay = Search.norm(text)
      [ hay, hay.scan(/[[:alnum:]]+/) ]
    end

    def term_score(term, hay, words)
      return nil if hay.empty?
      return 3 if words.include?(term)
      return 2 if words.any? { |w| w.start_with?(term) }
      return 1 if hay.include?(term)
      return nil if term.size < 4

      max = term.size >= 7 ? 2 : 1
      0.5 if words.any? { |w| near?(term, w, max) || (w.size > term.size && near?(term, w[0, term.size], max)) }
    end

    # Distância de Damerau-Levenshtein (com transposição) até `max`, com corte cedo.
    def near?(a, b, max)
      return false if (a.size - b.size).abs > max

      prev2 = nil
      prev = (0..b.size).to_a
      a.each_char.with_index(1) do |ca, i|
        cur = [ i ]
        b.each_char.with_index(1) do |cb, j|
          cost = ca == cb ? 0 : 1
          v = [ prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost ].min
          v = [ v, prev2[j - 2] + 1 ].min if prev2 && i > 1 && j > 1 && ca == b[j - 2] && a[i - 2] == cb
          cur << v
        end
        return false if cur.min > max

        prev2 = prev
        prev = cur
      end
      prev.last <= max
    end
  end
end
