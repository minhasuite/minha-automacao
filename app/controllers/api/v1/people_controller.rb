module Api
  module V1
    # Pessoas do local (Pacote 3): zona atual de cada uma (helpers Pessoa) e
    # as zonas com a contagem. Nunca coordenadas. Qualquer papel; chave com read.
    class PeopleController < BaseController
      self.key_actions = { index: "read" }

      def index
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        zones = People.zones(site).sort_by(&:name).map do |z|
          { "id" => z.id, "name" => z.name, "home" => HelperTypes::Zone.home?(z), "count" => z.value.to_i, "radius_m" => HelperTypes::Zone.radius(z).round }
        end
        render_data(People.summary(site), meta: { zones: zones })
      end
    end
  end
end
