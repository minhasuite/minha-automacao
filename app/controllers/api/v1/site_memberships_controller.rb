module Api
  module V1
    # Membros do local (papel por local, visitante com validade). Só o dono do local.
    class SiteMembershipsController < BaseController
      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :admin)
        records, meta = paginate(site.memberships.includes(:user).order(:created_at))
        render_data(SiteMembershipSerializer.new(records).to_h, meta: meta)
      end

      # POST { user_id, role, expires_at?, area_ids? } — a pessoa precisa ser da empresa.
      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :admin)
        user = current_tenant_record.users.find(params.require(:user_id))
        membership = site.memberships.create!(membership_params.merge(user: user))
        render_data(SiteMembershipSerializer.new(membership).to_h, status: :created)
      end

      def update
        membership = SiteMembership.find(params[:id])
        authorize_site!(membership.site, :admin)
        membership.update!(membership_params)
        render_data(SiteMembershipSerializer.new(membership).to_h)
      end

      def destroy
        membership = SiteMembership.find(params[:id])
        authorize_site!(membership.site, :admin)
        membership.destroy!
        head :no_content
      end

      private

      # O papel vem à parte (validado em SiteMembership::ROLES; só o dono do local chega aqui).
      def membership_params = params.permit(:expires_at, area_ids: []).merge({ role: params[:role] }.compact)
    end
  end
end
