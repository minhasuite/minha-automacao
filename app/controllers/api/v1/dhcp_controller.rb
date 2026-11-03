module Api
  module V1
    # Serviço dhcp-watch (resto, 7.23), com chave de integração "write":
    #   POST /dhcp/leases {leases: [{mac, hostname, ip, vendor, type}]}
    # Guarda o que ouviu (Host.dhcp junta com os vizinhos da sonda do host).
    class DhcpController < BaseController
      self.key_actions = { leases: "write" }

      def leases
        list = params.permit(leases: %i[mac hostname ip vendor type]).to_h.fetch("leases", [])
        render_data({ "stored" => Host.store_leases!(current_tenant_record, list) })
      end
    end
  end
end
