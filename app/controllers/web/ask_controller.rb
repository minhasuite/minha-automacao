module Web
  # "Perguntar à casa" (Lote 2, o `conversation.process` do HA): pergunta
  # livre sobre o estado atual, com os pontos do local (e o resumo das
  # últimas horas) como contexto. Só leitura: a IA não executa comando nem
  # vê nada além do texto do contexto. Qualquer papel no local.
  class AskController < ApplicationController
    def show
      @sites = Site.visible_to(current_user).order(:name).to_a
      @site = @sites.find { |s| s.id == params[:site_id] } || @sites.first
    end

    def create
      @sites = Site.visible_to(current_user).order(:name).to_a
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @question = params[:question].to_s.strip.truncate(1_000)
      return render(:show, status: :unprocessable_content) if @question.blank?

      @response = Ai::Ask.response(site: @site, question: @question)
      render :show
    rescue Ai::Client::Error => e
      @error = e.message
      render :show, status: :unprocessable_content
    end
  end
end
