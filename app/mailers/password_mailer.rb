# "Esqueci a senha": link (página /redefinir-senha) com o token de 30 min.
class PasswordMailer < ApplicationMailer
  def reset(user, token)
    @user = user
    @url = Rails.application.routes.url_helpers.reset_password_page_url(token: token)
    # No idioma escolhido pela pessoa (Minha conta); sem escolha, o padrão.
    I18n.with_locale(Localized.valid(user.dashboard_prefs&.dig("locale")) || I18n.default_locale) do
      mail(to: user.email, subject: t("mailers.password_reset.subject"))
    end
  end
end
