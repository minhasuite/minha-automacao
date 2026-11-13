module Pairing
  # Interface do adaptador de ponte de pareamento (um por protocolo). Os
  # métodos de rede publicam um pedido e voltam na hora: a resposta chega pelo
  # ouvinte, que grava `PairingBridge`/`PairingJoin`.
  class Adapter
    MAX_SECONDS = 254

    class << self
      # Chave = do plugin de integração (vai na URL e em `protocol`).
      def key = raise(NotImplementedError)
      def icon = "switch-horizontal"
      def max_seconds = MAX_SECONDS
      def label = I18n.t("pairing.protocols.#{key}.label", default: key.humanize)

      def available?(_site) = false
      def owns?(_device) = false
      def bridge(site) = PairingBridge.for(site, key)

      def open!(_site, _seconds, via: nil) = raise(NotImplementedError)
      def close!(_site) = raise(NotImplementedError)
      def rename!(_device, _name) = raise(NotImplementedError)
      def request_map!(_site) = raise(NotImplementedError)
      def name_error(_name) = nil

      # Roteadores por onde dá para abrir o pareamento (perto do aparelho): [[nome, id]].
      def routers(_site) = []

      # Mapa gravado → { nodes: [{id, name, role, device_id}], links: [{a, b, lqi, parent}] }.
      def graph(_bridge) = { nodes: [], links: [] }
    end
  end
end
