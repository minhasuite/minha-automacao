module Web
  # "Esqueci a senha" no web: mesmo e-mail da API (link para /redefinir-senha).
  class PasswordsController < ApplicationController
    skip_before_action :require_login!
    layout "auth"
    rate_limit to: 5, within: 15.minutes, only: :create, with: -> { redirect_to forgot_password_path, alert: I18n.t("notices.too_many_minutes") }

    def new; end

    def create
      user = User.find_by(email: params[:email].to_s.strip.downcase)
      if user && ApplicationMailer.deliverable?
        PasswordMailer.reset(user, user.generate_token_for(:password_recovery)).deliver_later
      elsif user
        Rails.logger.warn("[auth] redefinição pedida (user=#{user.id}) sem SMTP configurado: e-mail não enviado")
      end
      redirect_to login_path, notice: t("notices.reset_sent")
    end
  end
end
