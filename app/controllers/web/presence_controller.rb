module Web
  # Pessoas: quem está em casa e onde (zona e cômodo), o que cada fonte diz
  # agora (prioridade e confiança), as chegadas e saídas do dia e o assistente
  # "Presença pelo celular" de cada morador. Onde as pessoas estão é dado
  # sensível: só morador para cima (Maps::MIN_ROLE), como o Mapa. Criar a
  # pessoa pelo assistente é cadastro (técnico+). Ver docs/presenca.md.
  class PresenceController < ApplicationController
    include SitePick

    def show
      return redirect_to(sites_path, notice: t("notices.need_site_presence")) unless pick_site

      raise SiteMembership::Forbidden, t("notices.map_forbidden") unless Maps.allowed_role?(@site_role)

      @sites = @sites.select { |s| Maps.allowed_role?(s.role_for(current_user)) }
      @zones = People.zones(@site)
      @home = HelperTypes::Zone.home_of(@zones)
      @persons = People.persons(@site).to_a
      @tz = ActiveSupport::TimeZone[@site.timezone] || Time.zone
      @setup = People::Setup.rows(@site)
      @manage = can?(:manage)
    end

    # Assistente: cria a pessoa do morador com as fontes do celular dele.
    def create
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      user = User.find(params[:user_id])
      person, errors = People::Setup.create_person!(@site, user)
      return redirect_to(presence_path(site_id: @site.id), alert: errors.first(3).to_sentence) unless person

      redirect_to presence_path(site_id: @site.id, anchor: "p-#{person.id}"), notice: t("presence.setup.created", name: person.name)
    end
  end
end
