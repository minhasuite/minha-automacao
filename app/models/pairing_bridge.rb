# Estado da ponte de pareamento de um protocolo no local (docs/integracoes.md,
# "Zigbee"): pareamento aberto até `permit_until`, a ponte no ar (`state`),
# o resumo dela (`info`: versão, coordenador, canal) e o último mapa de rede
# (`network_map`, formato do adaptador; o zigbee2mqtt manda o "raw"). Quem
# grava é o ouvinte (worker); a tela só lê e pede.
class PairingBridge < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site

  validates :protocol, presence: true

  MAP_WAIT = 3.minutes

  def self.for(site, protocol)
    ActsAsTenant.with_tenant(site.tenant) { find_or_create_by!(site: site, protocol: protocol.to_s) }
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def open? = permit_until.present? && permit_until.future?
  def seconds_left = open? ? (permit_until - Time.current).ceil : 0
  def online? = state != "offline"

  # Pediu o mapa e a resposta ainda não chegou (o z2m leva de segundos a minutos).
  def map_pending? = network_map_requested_at.present? && network_map_requested_at > MAP_WAIT.ago &&
                     (network_map_at.nil? || network_map_at < network_map_requested_at)
end
