module Web
  # Busca global (Ctrl+K, uiweb): resultados das fontes do registro Search, na
  # paleta (?paleta=1: só os itens, sem as páginas, que a paleta já tem) ou na página, sem JS.
  class SearchController < ApplicationController
    def index
      @q = params[:q].to_s
      @results = Search.call(@q, current_user)
      return render(partial: "web/search/results", locals: { results: @results, q: @q }) if turbo_frame_request?
      return unless params[:paleta]

      page = I18n.t("search.kinds.page")
      render partial: "web/search/results", locals: { results: @results.reject { |r| r.kind == page }, q: @q }
    end
  end
end
