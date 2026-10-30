module Web
  # Configurações da instalação (F8d): Painéis, Pessoas, Chaves de integração
  # (controllers próprios) e Sistema (plano, exportar, zerar, backup e acesso
  # externo); mais "Minha conta". Sem dados de empresa na tela: o tenant
  # continua por dentro (acts_as_tenant).
  class SettingsController < ApplicationController
    before_action :require_owner!, only: :wipe

    def show = redirect_to(settings_dashboards_path)

    # Todos os painéis dos locais que a pessoa vê, com a coluna Local.
    def dashboards
      @sites = Site.visible_to(current_user).order(:name).to_a
      @roles = @sites.to_h { |s| [ s.id, s.role_for(current_user) ] }
      @sites.each { |s| Dashboard.ensure_for(s) }
      @dashboards = Dashboard.where(site_id: @sites.map(&:id)).includes(:site).order(:name).to_a
                             .select { |d| d.visible_to?(@roles[d.site_id]) }
    end

    def system
      Licencas::Sync.throttled(current_user.tenant)
      @billing = Billing::Status.call(current_user.tenant, current_user)
    end

    def account; end

    def update_account
      attrs = params.require(:account).permit(:name, :email)
      if params.dig(:account, :password).present?
        unless current_user.password_digest.blank? || current_user.authenticate(params.dig(:account, :current_password).to_s)
          return redirect_to(settings_account_path, alert: "Senha atual incorreta.")
        end

        attrs[:password] = params.dig(:account, :password)
      end
      current_user.update!(attrs)
      sign_in!(current_user) if attrs[:password]
      redirect_to settings_account_path, notice: "Conta atualizada."
    end

    def export
      send_data JSON.pretty_generate(Accounts::ExportData.call(current_user.tenant, current_user)),
                filename: "minha-automacao-#{Date.current}.json", type: "application/json"
    end

    def wipe
      return redirect_to(settings_system_path, alert: "Digite ZERAR para confirmar.") unless params[:confirm] == "ZERAR"

      Accounts::WipeData.call(current_user.tenant)
      redirect_to settings_system_path, notice: "Dados da instalação apagados."
    end

    def destroy_account
      return redirect_to(settings_account_path, alert: "Digite EXCLUIR para confirmar.") unless params[:confirm] == "EXCLUIR"

      tenant = current_user.tenant
      if tenant.users.where.not(id: current_user.id).exists?
        current_user.destroy!
      else
        Accounts::DestroyCompany.call(tenant)
      end
      reset_session
      redirect_to login_path, notice: "Conta excluída."
    end
  end
end
