module Web
  # Configurações → Chaves de integração (só o dono). Nome, locais permitidos,
  # permissões, validade, último uso e revogar. A chave em claro aparece só na
  # resposta da criação (nada de flash/cookie).
  class ApiKeysController < ApplicationController
    # Dias de validade ("" = sem validade); rótulos em api_keys.validity.
    VALIDITY = [ "30", "90", "365", "" ].freeze

    before_action :require_owner!

    def index
      @keys = ServiceApiKey.active.of_tenant(current_user.tenant).order(created_at: :desc).to_a
      @sites = Site.order(:name).to_a
    end

    def create
      p = params.require(:api_key).permit(:name, :validity, scopes: [], site_ids: [])
      days = p[:validity].to_s.presence_in(VALIDITY.compact_blank)
      @created, @plain = ServiceApiKey.issue(current_user, name: p[:name], scopes: p[:scopes], site_ids: p[:site_ids],
                                                           expires_at: (days.to_i.days.from_now if days))
      index
      render :index
    end

    def destroy
      key = ServiceApiKey.active.of_tenant(current_user.tenant).find(params[:id])
      key.revoke!
      redirect_to api_keys_path, notice: t("api_keys.flash.revoked", name: key.name)
    end
  end
end
