module Api
  module V1
    # Mapa do local para o app: zonas, pessoas (coordenada exata quando o
    # rastreador guarda, senão o centro da zona) e o trajeto do dia. Só
    # morador para cima (Maps::MIN_ROLE); chave de integração não lê.
    class MapsController < BaseController
      def index
        site = Site.find(params[:site_id])
        role = authorize_site!(site, :view)
        return render_error(:forbidden, "Seu papel neste local não mostra onde as pessoas estão.", status: :forbidden) unless Maps.allowed_role?(role)

        render_data(Maps.data(site, track: params[:track] != "false"))
      end
    end
  end
end
