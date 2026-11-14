# Base do WEB (Hotwire, sessão em cookie). A API herda de ActionController::API
# (Api::V1::BaseController) e não passa por aqui.
class ApplicationController < ActionController::Base
  include MeuLogInstrumented
  include Pagy::Backend
  include SiteAuthorization
  include KioskMode
  include Localized

  # O :modern do Rails pede Safari 17.2; o iPhone com iOS 16.4–17.1 (push e app na Tela de Início já
  # funcionam) levava 406. Mesmo piso do resto: CSS da gem (:has, color-mix, @layer, dvh) roda no 16.4.
  # Antes caía num public/406-unsupported-browser.html que não existe (erro 500): agora uma tela nos 3 idiomas.
  allow_browser versions: { safari: 16.4, chrome: 120, firefox: 121, opera: 106, ie: false },
                block: -> { render "web/pwa/unsupported_browser", layout: false, status: :not_acceptable }
  set_current_tenant_through_filter

  # appweb: pedido interno do app (AppScreen.dispatch, nunca vem de fora:
  # chave do env, não cabeçalho) entra com o usuário do token, sem CSRF.
  skip_forgery_protection if: -> { request.env.key?(AppScreen::ENV_KEY) }
  before_action :require_login!
  before_action :set_tenant
  before_action { Current.theme_key = cookies[:ma_theme].presence || current_user&.dashboard_prefs&.dig("theme") }

  helper_method :current_user, :can?, :reveal_sensitive?

  rescue_from SiteMembership::Forbidden do |e|
    back_with_alert(e.message)
  end

  rescue_from ActiveRecord::RecordNotFound do
    render "web/shared/not_found", status: :not_found, layout: current_user ? "application" : "auth"
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    back_with_alert(e.record.errors.full_messages.to_sentence)
  end

  private

  def meulog_usuario = current_user

  # Sessão: id do usuário + pedaço do digest da senha (trocou a senha, as
  # sessões web caem, como os tokens da API).
  def current_user
    return @current_user if defined?(@current_user)
    return @current_user = User.where(disabled_at: nil).find_by(id: request.env[AppScreen::ENV_KEY]) if request.env.key?(AppScreen::ENV_KEY)

    user = User.find_by(id: session[:user_id])
    return @current_user = user if user && !user.disabled? && session[:pwd] == user.password_digest.to_s.last(10)

    @current_user = remembered_user
  end

  # Lembrar o aparelho (pwa-ios, docs/pwa.md): o app da Tela de Início do iPhone tem cookies próprios e o
  # iOS fecha o processo a toda hora, o que apagava a sessão (cookie de sessão) e pedia a senha a cada
  # abertura. Ao entrar grava um cookie cifrado de REMEMBER_DAYS (pessoa + pedaço do digest da senha: trocar
  # a senha derruba), httponly e SameSite=Lax; sem sessão, ele refaz a sessão. Escrito só ao entrar, ao
  # refazer e ao sair (não a cada pedido, para um pedido em voo não desfazer o "Sair").
  REMEMBER = :ma_remember
  REMEMBER_DAYS = 30

  def remembered_user
    data = cookies.encrypted[REMEMBER]
    return nil unless data.is_a?(Hash)

    user = User.find_by(id: data["u"])
    return nil unless user && !user.disabled? && data["p"] == user.password_digest.to_s.last(10)

    session[:user_id] = user.id
    session[:pwd] = data["p"]
    remember!(user)
    user
  end

  def remember!(user)
    cookies.encrypted[REMEMBER] = { value: { "u" => user.id, "p" => user.password_digest.to_s.last(10) }, expires: REMEMBER_DAYS.days, httponly: true, same_site: :lax }
  end

  def forget!
    cookies.delete(REMEMBER)
  end

  def sign_in!(user)
    reset_session
    session[:user_id] = user.id
    session[:pwd] = user.password_digest.to_s.last(10)
    remember!(user)
    Current.user = user
    AuditEvent.login!(user, "web")
  end

  def require_login!
    return Current.user = current_user if current_user
    # Instalação nova, sem ninguém: a primeira configuração cria o dono.
    return redirect_to(onboarding_path) if Onboarding.fresh_install?

    redirect_to login_path(return_to: request.fullpath.presence_in([ request.fullpath ]))
  end

  def set_tenant
    set_current_tenant(current_user.tenant) if current_user
  end

  def require_owner!
    redirect_to root_path, alert: t("flash.owner_only") unless current_user.owner?
  end

  # Erro de formulário: volta para a página anterior com o aviso.
  def back_with_alert(message)
    redirect_back fallback_location: root_path, alert: message
  end

  # Linhas numeradas de formulário (`nome[0][campo]`, `nome[1][campo]`…) com os campos permitidos de cada uma
  # (itens do cartão, regras de estilo, limites do "dado velho"): {"0" => {...}, ...}.
  def form_rows(key, fields, from: params)
    rows = from[key]
    return {} unless rows.is_a?(ActionController::Parameters)

    rows.keys.select { |k| k.to_s.match?(/\A\d{1,2}\z/) }.to_h { |k| [ k, rows[k].is_a?(ActionController::Parameters) ? rows[k].permit(*fields).to_h : {} ] }
  end
end
