module Web
  # Agenda do local (ondaA1, A11): os eventos de todas as agendas (ICS,
  # Google e as locais) dos próximos 31 dias, por dia; nas agendas locais,
  # criar e apagar evento (com repetição). Melhor que o HA: uma visão só.
  class AgendaController < ApplicationController
    before_action -> { @site = Site.find(params[:site_id]) }

    def show
      authorize_site!(@site, :view)
      @calendars = @site.points.where(capability: "calendar", disabled: false).ordered.to_a
      @locals = @calendars.select { |p| p.helper == HelperTypes::LocalCalendar.key }
      zone = ActiveSupport::TimeZone[@site.timezone]
      today = Time.current.in_time_zone(zone).beginning_of_day
      events = @calendars.flat_map { |p| Calendars.events(p).map { |e| e.merge("calendar" => p) } }
      @days = events.select { |e| Time.zone.parse(e["end"]) > today }.sort_by { |e| e["start"] }
                    .group_by { |e| Time.zone.parse(e["start"]).in_time_zone(zone).to_date }
      @zone = zone
    end

    def create
      authorize_site!(@site, :manage)
      cal = local_calendar(params.dig(:event, :point_id))
      HelperTypes::LocalCalendar.add_event!(cal, params.require(:event).permit(:summary, :start, :end, :all_day, :location, :repeat).to_h)
      redirect_to site_agenda_path(@site), notice: "Evento criado em #{cal.name}."
    rescue ArgumentError => e
      redirect_to site_agenda_path(@site), alert: e.message
    end

    def destroy
      authorize_site!(@site, :manage)
      cal = local_calendar(params[:point_id])
      HelperTypes::LocalCalendar.remove_event!(cal, params[:uid])
      redirect_to site_agenda_path(@site), notice: "Evento apagado."
    end

    private

    def local_calendar(id) = @site.points.helpers.where(helper: HelperTypes::LocalCalendar.key).find(id)
  end
end
