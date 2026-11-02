# Base do WEB (Hotwire, sessão em cookie). A API herda de ActionController::API
# (Api::V1::BaseController) e não passa por aqui.
class ApplicationController < ActionController::Base
  include MeuLogInstrumented
  include Pagy::Backend
  include SiteAuthorization
  include KioskMode

  allow_browser versions: :modern
  set_current_tenant_through_filter

  before_action :require_login!
  before_action :set_tenant

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

    user = User.find_by(id: session[:user_id])
    @current_user = user if user && !user.disabled? && session[:pwd] == user.password_digest.to_s.last(10)
  end

  def sign_in!(user)
    reset_session
    session[:user_id] = user.id
    session[:pwd] = user.password_digest.to_s.last(10)
    Current.user = user
    AuditEvent.login!(user, "web")
  end

  def require_login!
    return Current.user = current_user if current_user

    redirect_to login_path(return_to: request.fullpath.presence_in([ request.fullpath ]))
  end

  def set_tenant
    set_current_tenant(current_user.tenant) if current_user
  end

  def require_owner!
    redirect_to root_path, alert: "Só o dono pode fazer isso." unless current_user.owner?
  end

  # Erro de formulário: volta para a página anterior com o aviso.
  def back_with_alert(message)
    redirect_back fallback_location: root_path, alert: message
  end
end
