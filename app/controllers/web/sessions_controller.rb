module Web
  # Entrar, criar conta e sair (web). Mesmas regras do AuthController da API.
  class SessionsController < ApplicationController
    skip_before_action :require_login!
    layout "auth"
    rate_limit to: 10, within: 1.minute, only: %i[create signup google], with: -> { redirect_to login_path, alert: "Muitas tentativas. Espere um minuto." }

    def new
      redirect_to root_path if current_user
    end

    def create
      user = User.find_by(email: params[:email].to_s.strip.downcase)
      if user&.password_digest.present? && user.authenticate(params[:password].to_s)
        sign_in!(user)
        redirect_to safe_return_to || root_path
      else
        flash.now[:alert] = "E-mail ou senha inválidos."
        render :new, status: :unprocessable_content
      end
    end

    # POST /entrar/google { credential } — o botão do Google (GIS) entrega o
    # id_token aqui pelo formulário da tela, com o token CSRF do Rails.
    def google
      return redirect_to(login_path, alert: "Login com Google indisponível.") if ENV["GOOGLE_CLIENT_ID"].blank?

      sign_in!(User.from_google!(params[:credential]))
      redirect_to safe_return_to || root_path
    rescue Google::Auth::IDTokens::VerificationError
      redirect_to login_path, alert: "Não foi possível entrar com o Google. Tente de novo."
    end

    def new_signup; end

    def signup
      user = nil
      ActiveRecord::Base.transaction do
        tenant = Tenant.create!(name: params[:company_name].presence || "Empresa de #{params[:name].to_s.split.first || 'você'}")
        user = User.create!(tenant: tenant, name: params[:name], email: params[:email], password: params[:password].to_s)
      end
      sign_in!(user)
      redirect_to root_path, notice: "Bem-vindo ao Minha Automação!"
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = e.record.errors.full_messages.to_sentence
      render :new_signup, status: :unprocessable_content
    end

    def destroy
      reset_session
      redirect_to login_path, notice: "Até logo!"
    end

    private

    def safe_return_to
      path = params[:return_to].to_s
      path if path.start_with?("/") && !path.start_with?("//")
    end
  end
end
