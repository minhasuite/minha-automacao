module Web
  # Configurações da instalação (F8d): Painéis, Pessoas, Chaves de integração
  # (controllers próprios) e Sistema (plano, exportar, zerar, backup e acesso
  # externo); mais "Minha conta". Sem dados de empresa na tela: o tenant
  # continua por dentro (acts_as_tenant).
  class SettingsController < ApplicationController
    before_action :require_owner!, only: %i[wipe update_system update_server]
    # Leitor só tem a própria conta (e os aparelhos de push).
    before_action :deny_reader!, except: %i[show account update_account destroy_account]

    def show = redirect_to(current_user.reader? ? settings_account_path : settings_dashboards_path)

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
      @release = Updates.latest(force: params[:verificar].present?)
      @update = Updates.status
    end

    # Produto: atualiza o servidor para a versão publicada (supervisor + bin/ma-update).
    def update_server
      Updates.start!(params[:tag])
      redirect_to settings_system_path, notice: t("updates.started")
    rescue Updates::Error => e
      redirect_to settings_system_path, alert: e.message
    end

    # Saída HTTP (ação "Chamar HTTP", agenda ICS): endereços internos liberados.
    def update_system
      tenant = current_user.tenant
      if params.key?(:shadow) # F10: sombra da instalação inteira
        on = ActiveModel::Type::Boolean.new.cast(params[:shadow])
        tenant.update!(settings: tenant.settings.merge("shadow" => on))
        return redirect_to(settings_system_path, notice: on ? "Instalação em sombra: nada comanda aparelho." : "Sombra da instalação desligada.")
      end

      tenant.update!(http_allow_text: params[:http_allow])
      redirect_to settings_system_path, notice: "Endereços liberados salvos."
    end

    def account; end

    def update_account
      attrs = params.require(:account).permit(:name, :email)
      if params.dig(:account, :password).present?
        unless current_user.password_digest.blank? || current_user.authenticate(params.dig(:account, :current_password).to_s)
          return redirect_to(settings_account_path, alert: t("flash.wrong_password"))
        end

        attrs[:password] = params.dig(:account, :password)
      end
      current_user.update!(attrs)
      sign_in!(current_user) if attrs[:password]
      redirect_to settings_account_path, notice: t("flash.account_saved")
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

    private

    def deny_reader!
      raise ActiveRecord::RecordNotFound if current_user.reader?
    end
  end
end
