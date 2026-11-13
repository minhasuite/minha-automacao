module Api
  module V1
    # Busca global do app (campo do Início): as mesmas fontes da web (`Search`),
    # já cortadas pelo papel. `GET /search?q=` → itens em ordem e agrupados
    # (`group` = título do grupo); sem `q`, os recentes da pessoa. `action` = o
    # POST da ação rápida pela API (papel x risco conferidos de novo na rota dela).
    # `POST /search/recent {key}` guarda o item aberto como recente. Ver docs/busca.md.
    class SearchController < BaseController
      def index
        q = params[:q].to_s
        ctx = Search::Context.for(current_user)
        results = q.blank? ? Search.recent(current_user, ctx) : Search.call(q, current_user)
        groups = results.map { |r| { kind: r.type, label: r.kind } }.uniq { |g| g[:label] }
        render_data(results.map { |r| item(r) }, meta: { q: q, groups: groups })
      end

      def recent
        result = Search.lookup(params[:key].to_s, Search::Context.for(current_user)) or return head(:not_found)

        Search::Recent.add!(current_user, result)
        head :no_content
      end

      private

      def item(r)
        { key: r.key, kind: r.type, group: r.kind, title: r.title, subtitle: r.subtitle, icon: r.icon, url: r.url, target: r.target,
          action: (r.action && r.api && { label: r.action[:label], method: "POST", path: r.api[:path], body: r.api[:body],
                                          confirm: r.action[:confirm], confirm_title: r.action[:confirm_title] }),
          recent: r.recent, favorite: r.favorite }
      end

      def viewer_allowed? = true
    end
  end
end
