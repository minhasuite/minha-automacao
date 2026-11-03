module Api
  module V1
    class MeController < BaseController
      def show = render_data(UserSerializer.new(current_user).to_h)

      # PATCH /me { name?, email?, password?, current_password? }
      def update
        attrs = params.permit(:name, :email).to_h
        # ondaB2 (B11): o tema do painel da pessoa (vazio = o do painel).
        if params.key?(:theme)
          key = params[:theme].presence
          return render_error(:invalid_theme, I18n.t("appearance.unknown"), status: :unprocessable_content) if key && !Dashboards::Themes[key]

          attrs[:dashboard_prefs] = current_user.dashboard_prefs.to_h.merge("theme" => key).compact
        end
        if params[:password].present?
          if current_user.password_digest.present? && !current_user.authenticate(params[:current_password].to_s)
            return render_error(:invalid_password, "Senha atual incorreta.", status: :unprocessable_content)
          end
          attrs[:password] = params[:password]
        end
        current_user.update!(attrs)
        render_data(UserSerializer.new(current_user).to_h)
      end

      # GET /themes — temas para escolher (os prontos e os da casa), com as cores.
      def themes
        render_data(Dashboards::Themes.all.map { |t| { key: t.key, label: t.label, accent: t.accent, accent2: t.accent2, glass: t.glass } },
                    meta: { current: current_user.dashboard_prefs.to_h["theme"] })
      end

      # DELETE /me — exclui a conta. Último membro leva a empresa junto.
      def destroy
        tenant = current_user.tenant
        if tenant.users.where.not(id: current_user.id).exists?
          current_user.destroy!
        else
          Accounts::DestroyCompany.call(tenant)
        end
        head :no_content
      end

      # GET /me/sessions — aparelhos com sessão ativa (sem tokens).
      def sessions
        tokens = current_user.api_tokens.active.where("refresh_expires_at > ?", Time.current).order(last_used_at: :desc)
        render_data(tokens.map do |t|
          { id: t.id, device_name: t.device_name, created_at: t.created_at, last_used_at: t.last_used_at, current: t.id == @current_api_token&.id }
        end)
      end

      # DELETE /me/sessions — encerra todas as OUTRAS sessões.
      def revoke_sessions
        scope = current_user.api_tokens.active
        scope = scope.where.not(id: @current_api_token.id) if @current_api_token
        render_data({ revoked: scope.update_all(revoked_at: Time.current) }) # rubocop:disable Rails/SkipsModelValidations
      end

      # DELETE /me/sessions/:id
      def revoke_session
        current_user.api_tokens.active.find(params[:id]).revoke!
        head :no_content
      end

      # GET /me/export — dados da empresa em JSON (LGPD).
      def export = render_data(Accounts::ExportData.call(current_tenant_record, current_user))

      # POST /me/wipe — zera o conteúdo da empresa (mantém conta e membros). Só o dono.
      def wipe
        return require_owner! unless current_user.owner?

        render_data({ deleted: Accounts::WipeData.call(current_tenant_record) })
      end
    end
  end
end
