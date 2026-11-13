module Pairing
  # Desenho simples do mapa da rede de malha, sem biblioteca: o grafo genérico
  # do adaptador ({nodes: [{id, name, role, device_id, failed}], links: [{a, b,
  # lqi, parent}]}) vira posições num quadro 1000×1000 para um SVG. Coordenador
  # no meio, roteadores no anel de dentro, aparelhos finais no anel de fora,
  # cada um perto do seu pai (o vizinho com relação de pai/filho ou o de
  # melhor sinal). Ligação repetida (A→B e B→A) vira uma, com o melhor sinal.
  module MapLayout
    SIZE = 1000
    CENTER = SIZE / 2
    INNER = 250
    OUTER = 430

    module_function

    def call(graph)
      nodes = graph[:nodes].uniq { |n| n[:id] }
      ids = nodes.to_set { |n| n[:id] }
      edges = merge(graph[:links].select { |l| ids.include?(l[:a]) && ids.include?(l[:b]) })
      center, others = nodes.partition { |n| n[:role] == "coordinator" }
      routers, ends = others.partition { |n| n[:role] == "router" }
      pos = {}
      center.each_with_index { |n, i| pos[n[:id]] = [ CENTER + (i * 40), CENTER ] }
      ring(routers.sort_by { |n| n[:name].to_s.downcase }, INNER, pos)
      parent = parents(ends, edges, pos)
      angle = ->(id) { (p = pos[parent[id]]) ? Math.atan2(p[1] - CENTER, p[0] - CENTER) : -Math::PI }
      ring(ends.sort_by { |n| [ angle.call(n[:id]), n[:name].to_s.downcase ] }, routers.empty? ? INNER : OUTER, pos)
      lqi = best_lqi(edges)
      { nodes: nodes.map { |n| n.merge(x: pos[n[:id]][0].round(1), y: pos[n[:id]][1].round(1), lqi: lqi[n[:id]], parent: parent[n[:id]]) }, edges: edges }
    end

    def ring(list, radius, pos)
      list.each_with_index do |n, i|
        a = (2 * Math::PI * i / [ list.size, 1 ].max) - (Math::PI / 2)
        pos[n[:id]] = [ CENTER + (radius * Math.cos(a)), CENTER + (radius * Math.sin(a)) ]
      end
    end

    def merge(links)
      links.group_by { |l| [ l[:a], l[:b] ].sort }.map do |(a, b), ls|
        { a: a, b: b, lqi: ls.map { |l| l[:lqi].to_i }.max, parent: ls.any? { |l| l[:parent] } }
      end
    end

    # Pai de cada aparelho final: ligação de pai/filho com quem já tem lugar (roteador ou coordenador), senão o melhor sinal.
    def parents(ends, edges, pos)
      ends.to_h do |n|
        mine = edges.select { |e| (e[:a] == n[:id] || e[:b] == n[:id]) }.map { |e| [ e, e[:a] == n[:id] ? e[:b] : e[:a] ] }.select { |_, o| pos[o] }
        best = mine.max_by { |e, _| [ e[:parent] ? 1 : 0, e[:lqi] ] }
        [ n[:id], best&.last ]
      end
    end

    def best_lqi(edges)
      edges.each_with_object({}) do |e, h|
        [ e[:a], e[:b] ].each { |id| h[id] = [ h[id].to_i, e[:lqi] ].max }
      end
    end

    # Faixa do sinal (0–255): good / fair / weak.
    def tone(lqi)
      return "muted" if lqi.nil?

      lqi >= Pairing::Network::GOOD ? "good" : (lqi >= Pairing::Network::WEAK ? "fair" : "weak")
    end
  end
end
