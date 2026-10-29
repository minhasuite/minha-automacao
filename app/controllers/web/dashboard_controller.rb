module Web
  class DashboardController < ApplicationController
    # Início: placeholder até o domínio de automação chegar (ESQUEMA-V1).
    def show
      @unread = Notification.for_user(current_user).unread.count
    end
  end
end
