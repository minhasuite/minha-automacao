module Web
  # "Perguntar à casa" (Lote 2, o `conversation.process` do HA): pergunta
  # livre sobre o estado atual, com os pontos do local (e o resumo das
  # últimas horas) como contexto. Só leitura: a IA não executa comando nem
  # vê nada além do texto do contexto. Qualquer papel no local.
  class AskController < ApplicationController
    SYSTEM = "Você é o assistente de uma instalação de automação (casa, loja ou fábrica). Responda em português do Brasil, " \
             "curto e direto, usando só o estado dos pontos informado abaixo. Se a informação não estiver lá, diga que não sabe. " \
             "Você não executa comandos: se pedirem para ligar ou desligar algo, explique que nesta fase só responde.".freeze
    HISTORY = 6.hours.to_i

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

      ctx = Automations::Context.new(site: @site)
      @response = Ai::Request.call(tenant: current_user.tenant, site: @site, source: "pergunta", system: SYSTEM, max_tokens: 800, timeout: 45,
                                   prompt: "#{Ai::PointContext.text(ctx, history_s: HISTORY)}\n\nPergunta: #{@question}")
      render :show
    rescue Ai::Client::Error => e
      @error = e.message
      render :show, status: :unprocessable_content
    end
  end
end
