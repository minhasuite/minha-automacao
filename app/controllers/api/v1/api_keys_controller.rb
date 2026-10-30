module Api
  module V1
    # Chaves de integração da instalação (só o dono). A chave em claro aparece
    # uma vez, na criação.
    class ApiKeysController < BaseController
      before_action :require_owner!

      def index
        render_data(ServiceApiKey.active.of_tenant(current_tenant_record).order(created_at: :desc).map { |k| payload(k) })
      end

      # POST { name, scopes: [read|command|write], site_ids: [], expires_at? }
      def create
        key, plain = ServiceApiKey.issue(current_user, name: params.require(:name), scopes: Array(params[:scopes]),
                                                       site_ids: Array(params[:site_ids]), expires_at: params[:expires_at].presence)
        render_data(payload(key).merge(token: plain), status: :created)
      end

      def destroy
        ServiceApiKey.active.of_tenant(current_tenant_record).find(params[:id]).revoke!
        head :no_content
      end

      private

      def payload(k)
        { id: k.id, name: k.name, scopes: k.scopes, site_ids: k.site_ids, expires_at: k.expires_at,
          last_used_at: k.last_used_at, created_at: k.created_at }
      end
    end
  end
end
