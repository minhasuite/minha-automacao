module Dashboards
  module Widgets
    # Lista automática (F5): os pontos do `query` (até 24); os que podem entrar
    # (sem o filtro de estado) são dependência do tempo real.
    class QueryListWidget < Base
      describe type: "query_list", label: "Lista automática", icon: "filter", required: %w[query], params: %w[empty_text]
      texts en: { label: "Smart list" },
            es: { label: "Lista automática" }

      def self.data(r, w, _binds)
        matched = r.query(w["query"]).first(Resolver::LIST_LIMIT).each { |p| r.use(p) }
        [ { "point_ids" => matched.map(&:id), "count" => r.query(w["query"]).size }, r.query(w["query"], with_state: false) ]
      end

      def self.attrs(p, _site = nil)
        q = query(p)
        { "query" => q.presence, "bind" => (p[:bind].presence if q.empty?), "empty_text" => p[:empty_text].presence }
      end

      def self.query(p) = p.fetch(:query, {}).to_h.compact_blank
      def self.form = %w[web/dashboards/widget_forms/query web/dashboards/widget_forms/query_list]
    end
  end
end
