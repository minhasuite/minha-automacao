module Web
  # "Expor para a Alexa" do local (F9): o que a skill Smart Home vê (pontos
  # com interface no registro Alexa::SmartHome::Interfaces e cenas), o nome
  # falado, os vínculos (contas da Alexa ligadas a este local) e o cliente
  # OAuth da instalação para o Developer Console. Ver: qualquer papel; mudar:
  # dono do local; cliente OAuth: dono da instalação.
  class AlexaController < ApplicationController
    before_action :load_site

    def show
      authorize_site!(@site, :view)
      @items = candidates
      @links = ApiToken.active.alexa.where(site_id: @site.id).where.not(last_used_at: nil).includes(:user).order(created_at: :desc).to_a
      @tenant = current_user.tenant
    end

    def update
      authorize_site!(@site, :admin)
      by_id = candidates.index_by { |t, _| Alexa::SmartHome.endpoint_id(t) }
      errors = params.fetch(:items, {}).to_unsafe_h.filter_map do |id, f|
        t = by_id[id]&.first or next
        t.assign_attributes(alexa_exposed: f[:exposed] == "1", alexa_name: f[:name], alexa_risk_confirmed: f[:confirm] == "1")
        next if !t.changed? || t.save

        t.errors.full_messages.to_sentence
      end
      redirect_to site_alexa_path(@site), **(errors.any? ? { alert: errors.first(3).to_sentence } : { notice: "Exposição salva. Diga \"Alexa, descobrir dispositivos\"." })
    end

    # Gera (ou refaz) o segredo do cliente; as URLs de retorno vêm da Amazon.
    def client
      authorize_site!(@site, :admin)
      return redirect_to(site_alexa_path(@site), alert: "Só o dono da instalação.") unless current_user.owner?

      tenant = current_user.tenant
      if params[:generate].present?
        @secret = tenant.generate_alexa_client!(params[:redirect_uris])
        @items = candidates
        @links = []
        @tenant = tenant
        flash.now[:notice] = "Cliente gerado. Copie o segredo agora: ele não aparece de novo."
        return render(:show)
      end
      tenant.update_alexa_redirects!(params[:redirect_uris])
      redirect_to site_alexa_path(@site), notice: "URLs de retorno salvas."
    end

    def unlink
      authorize_site!(@site, :admin)
      ApiToken.active.alexa.where(site_id: @site.id).find(params[:token_id]).revoke!
      redirect_to site_alexa_path(@site), notice: "Vínculo desfeito: a Alexa perde o acesso a este local."
    end

    private

    def load_site = @site = Site.find(params[:site_id])

    # [[ponto ou cena, interfaces]] que a Alexa entende.
    def candidates
      points = @site.points.includes(:device, :area).where(disabled: false).order(:name).to_a
      [ *points, *@site.scenes.order(:name) ].filter_map { |t| (ifaces = Alexa::SmartHome::Interfaces.for(t)).any? ? [ t, ifaces ] : nil }
    end
  end
end
