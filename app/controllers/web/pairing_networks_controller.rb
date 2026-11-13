module Web
  # Saúde e mapa da rede de malha (qualquer papel no local vê; pedir o mapa é
  # técnico+). A tabela vem dos aparelhos (`Pairing::Network`); o mapa é o
  # último que a ponte mandou, desenhado pelo `Pairing::MapLayout` em SVG.
  class PairingNetworksController < ApplicationController
    def show
      load_adapter(:view)
      @bridge = @adapter.bridge(@site)
      @layout = Pairing::MapLayout.call(@adapter.graph(@bridge)) if @bridge.network_map.present?
      nodes = @layout ? @layout[:nodes] : []
      @parents = nodes.to_h { |n| [ n[:id], n[:parent] ] }
      @names = nodes.to_h { |n| [ n[:id], n[:name] ] }
      @roles = nodes.to_h { |n| [ n[:id], n[:role] ] }
      rows = Pairing::Network.rows(@site, @adapter)
      @summary = Pairing::Network.summary(rows)
      @sort = params[:sort].presence_in(Pairing::Network::SORTS.keys) || "name"
      @dir = params[:dir] == "desc" ? "desc" : "asc"
      @rows = Pairing::Network.sort(rows, @sort, @dir)
    end

    def map
      load_adapter(:manage)
      @adapter.request_map!(@site)
      redirect_to site_pairing_network_path(@site, @adapter.key), notice: t("pairing.network.map_requested"), status: :see_other
    rescue Drivers::Mqtt::Error => e
      redirect_to site_pairing_network_path(@site, @adapter.key), alert: e.message, status: :see_other
    end

    private

    def load_adapter(action)
      @site = Site.find(params[:site_id])
      authorize_site!(@site, action)
      @adapter = Pairing.adapter(params[:protocolo]) or raise ActiveRecord::RecordNotFound
    end
  end
end
