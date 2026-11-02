module Web
  # Entrar, criar conta e sair (web). Mesmas regras do AuthController da API.
  class SessionsController < ApplicationController
    skip_before_action :require_login!
    layout "auth"
    rate_limit to: 10, within: 1.minute, only: %i[create signup google], with: -> { redirect_to login_path, alert: t("flash.too_many") }

    def new
      return redirect_to(onboarding_path) if Onboarding.fresh_install?

      redirect_to root_path if current_user
    end

    def create
      user = User.find_by(email: params[:email].to_s.strip.downcase)
      if user&.password_digest.present? && !user.disabled? && user.authenticate(params[:password].to_s)
        sign_in!(user)
        redirect_to safe_return_to || root_path
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

      sign_in!(user)
      redirect_to safe_return_to || root_path
    rescue Google::Auth::IDTokens::VerificationError
      redirect_to login_path, alert: t("flash.google_failed")
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

    def safe_return_to
      path = params[:return_to].to_s
      path if path.start_with?("/") && !path.start_with?("//")
    end
  end
end
