module Api
  module V1
    # A empresa, os convites e entrar em outra empresa por código.
    class CompaniesController < BaseController
      before_action :require_owner!, only: :update
      before_action :require_admin!, only: :invite

      def show = render_data(CompanySerializer.new(current_tenant_record).to_h)

      def update
        current_tenant_record.update!(params.permit(*CompanySerializer::EDITABLE))
        render_data(CompanySerializer.new(current_tenant_record).to_h)
      end

      # POST /company/invites { role? } → { code, role, expires_at } (o código só aparece aqui)
      def invite
        role = params[:role].presence_in(User::ROLES - %w[owner]) || "member"
        return render_error(:forbidden, "Só o dono convida administradores.", status: :forbidden) if role == "admin" && !current_user.owner?

        invite, code = Invite.generate!(created_by: current_user, role: role)
        render_data({ code: code, role: invite.role, expires_at: invite.expires_at }, status: :created)
      end

      # POST /company/join { code, discard_current? }
      def join
        tenant = Companies::Join.call(user: current_user, code: params.require(:code), discard_current: bool(params[:discard_current]))
        set_current_tenant(tenant)
        render_data(CompanySerializer.new(tenant).to_h)
      rescue Companies::Join::Error => e
        render_error(e.code, e.message, status: e.code == :company_not_empty ? :conflict : :unprocessable_content)
      end
    end
  end
end
