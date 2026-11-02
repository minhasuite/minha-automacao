module Web
  # Busca global (Ctrl+K, uiweb): resultados das fontes do registro Search,
  # no quadro da paleta (ou na página, sem JS).
  class SearchController < ApplicationController
    def index
      @q = params[:q].to_s
      @results = Search.call(@q, current_user)
      render partial: "web/search/results", locals: { results: @results, q: @q } if turbo_frame_request?
    end
  end
end
