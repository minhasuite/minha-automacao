# Páginas públicas: as exigidas pela Play (privacidade, termos, exclusão) e
# a de redefinir a senha (link do e-mail). Texto por idioma em
# app/views/legal/<página>.<idioma>.html.erb (pt-BR também tem o idioma no nome: com `i18n.fallbacks = [:en]`, um arquivo sem idioma perderia para o `.en`).
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

  # appweb2: Digital Asset Links. Com `ANDROID_APP_CERT_SHA256` (impressões
  # SHA-256 do certificado do app, separadas por vírgula) o Android deixa o
  # app criar e usar as passkeys deste domínio. Sem a variável: lista vazia.
  def assetlinks
    prints = Passkeys.android_prints
    render json: prints.empty? ? [] : [ { relation: %w[delegate_permission/common.handle_all_urls delegate_permission/common.get_login_creds],
                                          target: { namespace: "android_app", package_name: Passkeys::ANDROID_PACKAGE, sha256_cert_fingerprints: prints } } ]
  end

  private

  # Localized: estas páginas não têm sessão; vale o cookie ou o navegador.
  def current_user = nil
end
