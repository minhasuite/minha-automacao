module ApplicationCable
  # WebSocket da web: mesma sessão em cookie do ApplicationController (id +
  # pedaço do digest da senha). Sem login, a conexão é recusada.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      user = User.find_by(id: request.session[:user_id])
      reject_unauthorized_connection unless user && request.session[:pwd] == user.password_digest.to_s.last(10)
      self.current_user = user
    end
  end
end
