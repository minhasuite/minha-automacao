module Web
  # Configurações: empresa (dono), plano, chaves de integração e conta
  # (senha, exportar, zerar, excluir). Mesmas regras da API.
  class SettingsController < ApplicationController
    before_action :require_owner!, only: %i[update_company wipe]

    def show
      @company = current_user.tenant
      Licencas::Sync.throttled(@company)
      @billing = Billing::Status.call(@company, current_user)
    end

    def update_company
      current_user.tenant.update!(params.require(:company).permit(*CompanySerializer::EDITABLE))
      redirect_to settings_path, notice: "Empresa atualizada."
    end

    def update_account
      attrs = params.require(:account).permit(:name, :email)
      if params.dig(:account, :password).present?
        unless current_user.password_digest.blank? || current_user.authenticate(params.dig(:account, :current_password).to_s)
          return redirect_to(settings_path, alert: "Senha atual incorreta.")
        end

        attrs[:password] = params.dig(:account, :password)
      end
      current_user.update!(attrs)
      sign_in!(current_user) if attrs[:password]
      redirect_to settings_path, notice: "Conta atualizada."
    end

    def export
      send_data JSON.pretty_generate(Accounts::ExportData.call(current_user.tenant, current_user)),
                filename: "minha-automacao-#{Date.current}.json", type: "application/json"
    end

    def wipe
      return redirect_to(settings_path, alert: "Digite ZERAR para confirmar.") unless params[:confirm] == "ZERAR"

      Accounts::WipeData.call(current_user.tenant)
      redirect_to settings_path, notice: "Dados da empresa apagados."
    end

    def destroy_account
      return redirect_to(settings_path, alert: "Digite EXCLUIR para confirmar.") unless params[:confirm] == "EXCLUIR"

      tenant = current_user.tenant
      if tenant.users.where.not(id: current_user.id).exists?
        current_user.destroy!
      else
        Accounts::DestroyCompany.call(tenant)
      end
      reset_session
      redirect_to login_path, notice: "Conta excluída."
    end

    # Código de convite (administrador; só o dono convida administrador).
    def invite
      return redirect_to(settings_path, alert: "Só administrador ou dono pode convidar.") unless current_user.admin?

      role = params[:role].presence_in(User::ROLES - %w[owner]) || "member"
      return redirect_to(settings_path, alert: "Só o dono convida administradores.") if role == "admin" && !current_user.owner?

      _invite, code = Invite.generate!(created_by: current_user, role: role)
      redirect_to settings_path(anchor: "convites"), notice: "Código do convite: #{code} (vale 7 dias, uso único)."
    end

    def join
      Companies::Join.call(user: current_user, code: params[:code].to_s, discard_current: params[:discard_current] == "1")
      redirect_to root_path, notice: "Você entrou na empresa."
    rescue Companies::Join::Error => e
      redirect_to settings_path, alert: e.message
    end
  end
end
