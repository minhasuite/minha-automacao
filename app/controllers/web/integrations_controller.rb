module Web
  # Integrações do local (F8): contas (Alexa) e aparelhos com conexão própria
  # (robô Xiaomi), com estado, último sucesso e último erro. Ver: qualquer
  # papel; atualizar a lista de Echo (só leitura na conta): técnico ou dono.
  class IntegrationsController < ApplicationController
    def index
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :view)
      @integrations = @site.integrations.includes(:devices).order(:name)
      @direct = @site.devices.where(driver: "xiaomi_miot").order(:name)
    end

    def discover
      integration = Integration.find(params[:id])
      authorize_site!(integration.site, :manage)
      r = Alexa::Import.discover!(integration)
      redirect_to site_integrations_path(integration.site), notice: "Lista atualizada: #{r[:echos]} Echo na conta, #{r[:devices]} nova(s)."
    rescue Alexa::Client::Error, Drivers::Alexa::Error => e
      redirect_to site_integrations_path(integration.site), alert: "Não deu para atualizar: #{e.message}"
    end
  end
end
