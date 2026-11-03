module Api
  module V1
    # App do celular (F7, G17; Integrations::MobileAppPlugin). O celular se
    # registra no local (qualquer papel nele) e manda os sensores que a pessoa
    # ligou. O aparelho é da pessoa: só ela manda leitura ou o remove. Chave de
    # integração não entra aqui.
    class MobileDevicesController < BaseController
      INSTALL_ID = /\A[A-Za-z0-9_-]{8,64}\z/

      # POST /sites/:site_id/mobile_devices { install_id, name, model?, platform? }
      def create
        site = Site.find(params[:site_id])
        authorize_site!(site, :view)
        install_id = params.require(:install_id).to_s
        return render_error(:invalid_parameter, "install_id inválido.", status: :bad_request) unless install_id.match?(INSTALL_ID)

        device = Integrations::MobileAppPlugin.register!(site, current_user, install_id: install_id, name: params.require(:name).to_s.first(80),
                                                                             model: params[:model].to_s.first(80), platform: params[:platform].to_s.first(20))
        render_data(payload(device), status: :created)
      end

      # POST /mobile_devices/:id/sensors { battery?, charging?, wifi?, location?: {latitude, longitude, accuracy} }
      def sensors
        device = own_device
        fields = Integrations::MobileAppPlugin::SENSORS.keys - [ "location" ]
        lists = fields.index_with { [] } # appweb2: sensor que manda lista (ex.: bt_devices)
        Integrations::MobileAppPlugin.report!(device, params.permit(*fields, location: %i[latitude longitude accuracy], **lists).to_h)
        render_data(payload(device.reload))
      end

      # POST /mobile_devices/:id/tag { tag } — appweb D4: o celular leu uma tag
      # (NFC ou QR `minhaautomacao://tag/<id>`); dispara o gatilho "Tag lida".
      def tag
        device = own_device
        tag = params.require(:tag).to_s.strip.first(120)
        return render_error(:invalid_parameter, "tag inválida.", status: :bad_request) unless tag.match?(/\A[\w.:-]+\z/)

        Automations::Triggers.event(device.site_id, Automations::TriggerTypes::TagTrigger::EVENT,
                                    { "tag" => tag, "user" => current_user.name, "user_id" => current_user.id, "device" => device.name })
        render_data({ tag: tag })
      end

      # DELETE /mobile_devices/:id — tira o celular (e os pontos dele) do local.
      def destroy
        own_device.destroy!
        head :no_content
      end

      private

      # O celular é da própria pessoa: o Leitor também registra o dele.
      def viewer_allowed? = true

      def own_device
        device = Device.find(params[:id])
        raise ActiveRecord::RecordNotFound unless Integrations::MobileAppPlugin.mobile?(device) && device.address["user_id"] == current_user.id

        authorize_site!(device.site, :view)
        device
      end

      # appweb2 D1: casa e zonas (centro e raio) para o celular vigiar com o
      # geofence do Android em segundo plano; ao entrar/sair ele manda a
      # localização e o servidor resolve a zona como sempre.
      def geofences(site)
        home = { "id" => "home", "name" => Integrations::MobileAppPlugin::HOME, "latitude" => site.latitude&.to_f, "longitude" => site.longitude&.to_f,
                 "radius" => site.integrations.find_by(driver: Integrations::MobileAppPlugin.driver)&.settings&.dig("home_radius_m") || Integrations::MobileAppPlugin::HOME_RADIUS_M }
        zones = People.zones(site).filter_map do |z|
          lat, lon = HelperTypes::Zone.center(z)
          { "id" => z.id, "name" => z.name, "latitude" => lat&.to_f, "longitude" => lon&.to_f, "radius" => HelperTypes::Zone.radius(z).to_f }
        end
        [ home, *zones ].select { |z| z["latitude"] && z["longitude"] && z["radius"].to_f.positive? }.first(90)
      end

      # Pacote 3: `zone` = zona onde a última localização caiu (nunca a coordenada).
      def payload(device)
        points = device.points.ordered.to_a
        DeviceSerializer.new(device, params: { reveal: true }).to_h.merge("points" => PointSerializer.new(points, params: { reveal: true }).to_h, # o celular é da pessoa
                                                                       "zone" => points.find { |p| p.device_class == "location" }&.attrs&.dig("zone"),
                                                                       "zones" => geofences(device.site))
      end
    end
  end
end
