module Api
  module V1
    # Serviço ble-scanner (ondaC1, C2), com a chave gerada na tela Gerenciar
    # da integração Bluetooth (permissão "write"):
    #   POST /bluetooth/advertisements {adapter: {name, address}, adverts: [{mac, rssi, data}]}
    # `data` = anúncio cru em base64. Vai para a integração Bluetooth do local da chave.
    class BluetoothController < BaseController
      self.key_actions = { advertisements: "write" }

      def advertisements
        integration = Integration.where(driver: "bluetooth", site_id: visible_sites.select(:id)).order(:created_at).first or
          return render_error(:not_found, "Nenhuma integração Bluetooth neste local.", status: :not_found)
        authorize_site!(integration.site, :view)
        adverts = params.permit(adverts: %i[mac rssi data]).to_h.fetch("adverts", []).map { |a| a.merge("rssi" => Integer(a["rssi"].to_s, exception: false)) }
        adapter = params.permit(adapter: %i[name address]).to_h["adapter"]
        render_data({ "understood" => Ble::Hub.ingest!(integration, adverts, adapter: adapter) })
      end
    end
  end
end
