module Web
  # GET /desde?desde=<ISO> → o cartão "desde a última visita" do Início (o src: do Ss::SinceLastVisitComponent: o
  # ss-since guarda a visita no navegador e busca o cartão com ela). Sem data, corpo vazio.
  class SinceLastVisitController < ApplicationController
    def show
      @since = Time.zone.parse(params[:desde].to_s)
      return head(:no_content) unless @since

      @items = SinceLastVisit.call(user: current_user, since: @since)
      render layout: false
    rescue ArgumentError
      head :no_content
    end
  end
end
