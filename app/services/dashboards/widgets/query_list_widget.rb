module Dashboards
  module Widgets
    # Lista automática (F5): os pontos do `query` (até 24); os que podem entrar
    # (sem o filtro de estado) são dependência do tempo real.
    #
    # O auto-entities do HA traz mais três coisas, todas opcionais:
    #   `or`      — outras consultas somadas à primeira (cada regra `include` do
    #               HA vira uma; a ordem é a do `sort` da primeira);
    #   `display` — "rows" (lista, o padrão) ou "tiles" (grade de tiles, `columns` 1–4 no computador);
    #   `labels`  — {id do ponto → nome} para o nome que o painel do HA dava.
    class QueryListWidget < Base
      describe type: "query_list", label: "Lista automática", icon: "filter", required: %w[query], params: %w[empty_text display]
      texts en: { label: "Smart list", bad_or: "the extra queries must be a list (up to %{max})", bad_display: "display must be rows or tiles" },
            es: { label: "Lista automática", bad_or: "las consultas extra deben ser una lista (hasta %{max})", bad_display: "la vista debe ser rows o tiles" },
            "pt-BR" => { bad_or: "as consultas a mais precisam ser uma lista (até %{max})", bad_display: "a exibição é rows ou tiles" }

      MAX_OR = 30
      DISPLAYS = %w[rows tiles].freeze

      def self.errors(w)
        e = []
        e << text(:bad_or, max: MAX_OR) if w.key?("or") && !(w["or"].is_a?(Array) && w["or"].size <= MAX_OR && w["or"].all?(Hash))
        e << text(:bad_display) if w.key?("display") && !DISPLAYS.include?(w["display"])
        e << text(:bad_display) if w.key?("columns") && !(w["columns"].is_a?(Integer) && w["columns"].between?(1, 4))
        e << text(:bad_or, max: MAX_OR) if w.key?("labels") && !w["labels"].is_a?(Hash)
        e
      end

      def self.data(r, w, _binds)
        all = matches(r, w)
        all.first(Resolver::LIST_LIMIT).each { |p| r.use(p) }
        [ { "point_ids" => all.first(Resolver::LIST_LIMIT).map(&:id), "count" => all.size }, matches(r, w, with_state: false) ]
      end

      # A primeira consulta e as do `or`, sem repetir ponto, na ordem do `sort` da primeira.
      def self.matches(r, w, with_state: true)
        queries = [ w["query"], *Array(w["or"]) ].select { |q| q.is_a?(Hash) }
        return r.query(queries.first, with_state: with_state) if queries.size <= 1

        found = queries.flat_map { |q| r.query(q, with_state: with_state) }.uniq(&:id)
        r.sort(found, w.dig("query", "sort"))
      end

      def self.attrs(p, _site = nil)
        q = query(p)
        { "query" => q.presence, "bind" => (p[:bind].presence if q.empty?), "empty_text" => p[:empty_text].presence,
          "display" => (p[:display] if DISPLAYS.include?(p[:display]) && p[:display] != "rows") }
      end

      # Filtros que o formulário mostra; os outros (id, automation, ran_min…) vêm do HA e ficam ao editar.
      FORM_QUERY = %i[capability state tag area device_class quality integration unchanged_min exclude sort].freeze

      def self.keep(old, new)
        hidden = old["query"].to_h.except(*FORM_QUERY.map(&:to_s))
        new.merge(old.slice("or", "labels", "columns")).merge("query" => hidden.merge(new["query"].to_h).presence).compact
      end

      def self.query(p) = p.fetch(:query, {}).to_h.compact_blank
      def self.form = %w[web/dashboards/widget_forms/query web/dashboards/widget_forms/query_list]
    end
  end
end
