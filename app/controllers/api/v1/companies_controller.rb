module Api
  module V1
    # A instalação (o tenant; o app não mostra "empresa") e o convite por link.
    class CompaniesController < BaseController
      before_action :require_owner!, only: %i[update invite]

      def show = render_data(CompanySerializer.new(current_tenant_record).to_h)

      def update
        current_tenant_record.update!(params.permit(*CompanySerializer::EDITABLE))
        render_data(CompanySerializer.new(current_tenant_record).to_h)
      end

      # POST /company/invites { role?, site_id?, site_role? } → { url, role, expires_at }
      # (o link só aparece aqui; abre o cadastro direto nesta instalação).
      def invite
        site = Site.find(params[:site_id]) if params[:site_id].present?
        invite, token = Invite.generate!(created_by: current_user, role: params[:role].presence_in(User::ROLES - %w[owner]) || "member",
                                         site: site, site_role: params[:site_role].presence)
        render_data({ url: invite_link_url(token), role: invite.role, site_id: invite.site_id, site_role: invite.site_role,
                      expires_at: invite.expires_at }, status: :created)
      end
    end
  end
end
