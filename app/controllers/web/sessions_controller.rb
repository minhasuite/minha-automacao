module Web
  # Entrar, criar conta e sair (web). Mesmas regras do AuthController da API.
  class SessionsController < ApplicationController
    skip_before_action :require_login!
    layout "auth"
    rate_limit to: 10, within: 1.minute, only: %i[create signup google verify_mfa passkey], with: -> { redirect_to login_path, alert: t("flash.too_many") }
    MFA_WINDOW = 5.minutes

    def new
      return redirect_to(onboarding_path) if Onboarding.fresh_install?

      redirect_to root_path if current_user
    end

    def create
      user = User.find_by(email: params[:email].to_s.strip.downcase)
      if user&.password_digest.present? && !user.disabled? && user.authenticate(params[:password].to_s)
        finish_login(user)
      else
        flash.now[:alert] = t("flash.bad_login")
        render :new, status: :unprocessable_content
      end
    end

    # POST /entrar/google { credential } — o botão do Google (GIS) entrega o
    # id_token aqui pelo formulário da tela, com o token CSRF do Rails.
    def google
      return redirect_to(login_path, alert: t("flash.google_off")) if ENV["GOOGLE_CLIENT_ID"].blank?

      user = User.from_google!(params[:credential])
      return redirect_to(login_path, alert: t("flash.google_disabled")) if user.disabled?

      finish_login(user)
    rescue Google::Auth::IDTokens::VerificationError
      redirect_to login_path, alert: t("flash.google_failed")
    end

    # ondaA2 A16: segunda etapa (código do app autenticador ou de recuperação).
    def mfa
      redirect_to login_path unless pending_mfa_user
    end

    def verify_mfa
      user = pending_mfa_user or return redirect_to(login_path, alert: t("security.login.expired"))
      unless Mfa.verify(user, params[:code])
        flash.now[:alert] = t("security.totp.bad_code")
        return render(:mfa, status: :unprocessable_content)
      end

      to = session[:mfa]["to"]
      sign_in!(user)
      redirect_to to || root_path
    end

    # Entrar com passkey: sem senha e sem código (a passkey já é posse + biometria/PIN).
    def passkey_options
      session[:passkey_login] = Passkeys.challenge
      render json: Passkeys.request_options(rp_id: request.host, challenge: session[:passkey_login])
    end

    def passkey
      key = Passkeys.authenticate!(params, challenge: session.delete(:passkey_login), origin: request.base_url, rp_id: request.host)
      return render(json: { error: t("flash.google_disabled") }, status: :forbidden) if key.user.disabled?

      sign_in!(key.user)
      render json: { redirect: safe_return_to || root_path }
    rescue Passkeys::Error
      render json: { error: t("security.passkeys.failed") }, status: :unauthorized
    end

    def new_signup; end

    def signup
      user = nil
      ActiveRecord::Base.transaction do
        tenant = Tenant.create!(name: t("onboarding.account.tenant_name", name: params[:name].to_s.split.first || "-"))
        user = User.create!(tenant: tenant, name: params[:name], email: params[:email], password: params[:password].to_s)
      end
      sign_in!(user)
      redirect_to root_path, notice: t("flash.welcome")
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = e.record.errors.full_messages.to_sentence
      render :new_signup, status: :unprocessable_content
    end

    def destroy
      reset_session
      redirect_to login_path, notice: t("flash.bye")
    end

    private

    def finish_login(user)
      unless Mfa.required?(user)
        sign_in!(user)
        return redirect_to(safe_return_to || root_path)
      end

      reset_session
      session[:mfa] = { "id" => user.id, "at" => Time.current.to_i, "to" => safe_return_to }
      redirect_to login_mfa_path
    end

    def pending_mfa_user
      m = session[:mfa]
      return nil unless m.is_a?(Hash) && m["at"].to_i > MFA_WINDOW.ago.to_i

      User.find_by(id: m["id"])&.then { |u| u unless u.disabled? }
    end

    def safe_return_to
      path = params[:return_to].to_s
      path if path.start_with?("/") && !path.start_with?("//")
    end
  end
end
