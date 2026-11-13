module Web
  # Busca global (Ctrl+K, uiweb): resultados das fontes do registro Search, na
  # paleta (?paleta=1: só os itens, sem as páginas, que a paleta já tem) ou na página, sem JS.
  # Abrir um resultado passa por `/busca/abrir?k=` (guarda nos recentes da pessoa e
  # redireciona para o endereço que a própria fonte dá: nada de endereço vindo do pedido).
  class SearchController < ApplicationController
    def index
      @q = params[:q].to_s
      @results = Search.call(@q, current_user)
      @recent = @q.blank? ? Search.recent(current_user).first(8) : []
      return render(partial: "web/search/results", locals: { results: @results, q: @q, recent: [] }) if turbo_frame_request?
      return unless params[:paleta]

      render partial: "web/search/results", locals: { results: @results.reject { |r| r.type == "page" }, q: @q, recent: [] }
    end

    def open
      result = Search.lookup(params[:k].to_s, Search::Context.for(current_user)) or return redirect_to(search_path, alert: t("search.gone"))

      Search::Recent.add!(current_user, result)
      redirect_to result.url, status: :see_other
    end

    private

    # Leitor (viewer) também busca o que vê.
    def viewer_allowed? = true
  end
end
