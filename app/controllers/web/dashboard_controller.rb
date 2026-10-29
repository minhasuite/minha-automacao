module Web
  class DashboardController < ApplicationController
    # Início: os locais da pessoa, ou o convite para criar o primeiro.
    def show
      @unread = Notification.for_user(current_user).unread.count
      @sites = Site.visible_to(current_user).order(:name).to_a
      @points_count = Point.where(site_id: @sites.map(&:id)).count
    end
  end
end
