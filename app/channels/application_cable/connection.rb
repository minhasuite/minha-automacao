module ApplicationCable
  # WebSocket da web: mesma sessão em cookie do ApplicationController (id +
  # pedaço do digest da senha). O app (F7) entra com o access token da API em
  # `?access_token=` (o mesmo Bearer; vence em 30 min, o app reconecta com o
  # novo). Sem login, a conexão é recusada.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = app_user || web_user || reject_unauthorized_connection
    end

    private

    def web_user
      user = User.find_by(id: request.session[:user_id])
      user if user && request.session[:pwd] == user.password_digest.to_s.last(10)
    end

    def app_user
      token = request.params[:access_token].presence or return
      user = ApiToken.find_by_access(token)&.user
      user unless user.nil? || user.disabled?
    end
  end
end
