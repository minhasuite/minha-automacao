# Páginas públicas: as exigidas pela Play (privacidade, termos, exclusão) e
# a de redefinir a senha (link do e-mail). Texto por idioma em
# app/views/legal/<página>.<idioma>.html.erb (pt-BR é o arquivo sem idioma).
class LegalController < ActionController::Base
  include Localized
  layout "legal"

  UPDATED_ON = Date.new(2026, 10, 10)

  before_action { @updated_on = UPDATED_ON }

  def privacy; end
  def terms; end
  def data_deletion; end

  # Página do link do e-mail "esqueci a senha": o formulário chama
  # POST /api/v1/auth/password/reset (o token vai da URL para o corpo).
  def reset_password
    @updated_on = nil
  end

  private

  # Localized: estas páginas não têm sessão; vale o cookie ou o navegador.
  def current_user = nil
end
