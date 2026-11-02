module Web
  # Diário (Logbook do HA): tudo o que aconteceu no local, com filtros e
  # rolagem infinita (a próxima página é um turbo-frame preguiçoso).
  class LogbookController < ApplicationController
    include SitePick

    FILTERS = [ :site_id, :period, :from, :until, :area_id, :device_id, :point_id, :user_id, :q, :before, :day, { sources: [] } ].freeze

    def show
      return redirect_to(sites_path, notice: t("notices.need_site_logbook")) unless pick_site

      @filter = Logbook::Filter.new(site: @site, role: @site_role, params: params.permit(*FILTERS))
      @items, @next = Logbook.call(@filter)
      @zone = ActiveSupport::TimeZone[@site.timezone] || Time.zone
      return unless params[:before].present? && turbo_frame_request?

      render partial: "page", locals: { items: @items, next_cursor: @next, filter: @filter, zone: @zone, day: params[:day], frame: params[:before] }
    end
  end
end
