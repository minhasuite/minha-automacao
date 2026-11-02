module Web
  # Configurações → Segurança (ondaA2 A16): app autenticador (TOTP) com
  # códigos de recuperação e passkeys da própria pessoa.
  class SecurityController < ApplicationController
    def show
      @user = current_user
      session[:totp_pending] ||= Mfa::Totp.new_secret unless Mfa::Totp.enabled?(@user)
      @secret = session[:totp_pending]
      @codes = session.delete(:recovery_codes)
    end

    def enable_totp
      secret = session[:totp_pending].to_s
      return redirect_to(settings_security_path, alert: t("security.totp.bad_code")) unless secret.present? && Mfa::Totp.match(secret, params[:code])

      current_user.update!(otp_secret: secret, otp_enabled_at: Time.current, otp_last_step: nil)
      session.delete(:totp_pending)
      session[:recovery_codes] = Mfa::RecoveryCodes.generate!(current_user)
      audit!("mfa.on")
      redirect_to settings_security_path, notice: t("security.totp.enabled")
    end

    # Desligar pede um código válido (do app ou de recuperação).
    def disable_totp
      return redirect_to(settings_security_path, alert: t("security.totp.bad_code")) unless Mfa.verify(current_user, params[:code])

      current_user.update!(otp_secret: nil, otp_enabled_at: nil, otp_last_step: nil, otp_recovery: [])
      audit!("mfa.off")
      redirect_to settings_security_path, notice: t("security.totp.disabled")
    end

    def recovery
      return redirect_to(settings_security_path) unless Mfa::Totp.enabled?(current_user)

      session[:recovery_codes] = Mfa::RecoveryCodes.generate!(current_user)
      redirect_to settings_security_path, notice: t("security.recovery.renewed")
    end

    def passkey_options
      session[:passkey_challenge] = Passkeys.challenge
      render json: Passkeys.creation_options(current_user, rp_id: request.host, challenge: session[:passkey_challenge])
    end

    def create_passkey
      Passkeys.register!(current_user, params, challenge: session.delete(:passkey_challenge), origin: request.base_url, rp_id: request.host)
      audit!("passkey.add")
      flash[:notice] = t("security.passkeys.added")
      render json: { redirect: settings_security_path }
    rescue Passkeys::Error
      render json: { error: t("security.passkeys.failed") }, status: :unprocessable_content
    end

    def destroy_passkey
      current_user.passkeys.find(params[:id]).destroy!
      audit!("passkey.remove")
      redirect_to settings_security_path, notice: t("security.passkeys.removed")
    end

    private

    def audit!(action) = AuditEvent.create!(tenant_id: current_user.tenant_id, user_id: current_user.id, action: action, auditable_type: "User", auditable_id: current_user.id, details: {})
  end
end
