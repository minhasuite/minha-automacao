# "Esqueci a senha": link (página /redefinir-senha) com o token de 30 min.
class PasswordMailer < ApplicationMailer
  def reset(user, token)
    @user = user
    @url = Rails.application.routes.url_helpers.reset_password_page_url(token: token)
    mail(to: user.email, subject: "Minha Automação: redefinir sua senha")
  end
end
