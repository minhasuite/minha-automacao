module Web
  # Mapa: pessoas, zonas e o trajeto do dia (Leaflet + OpenStreetMap). Só
  # morador para cima (Maps::MIN_ROLE); visitante e operador recebem 403.
  class MapsController < ApplicationController
    include SitePick

    def show
      return redirect_to(sites_path, notice: "Crie um local para ver o mapa.") unless pick_site

      raise SiteMembership::Forbidden, "Seu papel neste local não mostra onde as pessoas estão." unless Maps.allowed_role?(@site_role)

      @sites = @sites.select { |s| Maps.allowed_role?(s.role_for(current_user)) }
      @map = Maps.data(@site)
    end
  end
end
