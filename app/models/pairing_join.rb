# Aparelho que entrou na rede pelo assistente de pareamento (docs/integracoes.md,
# "Zigbee"): o ouvinte anota entrou → entrevista (iniciada, concluída, falhou)
# → saiu; a descoberta liga ao `device` quando ele vira aparelho daqui, e a
# pessoa decide (`resolution`): é novo (nome e área) ou substitui um aparelho
# existente (`Devices::Replace`). Um registro por aparelho e protocolo no local.
class PairingJoin < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :device, optional: true

  STATUSES = %w[joined interviewing successful failed left].freeze
  RESOLUTIONS = %w[new replaced dismissed].freeze
  # Some da lista do assistente depois disso (a decisão já foi tomada ou o aparelho sumiu).
  RECENT = 12.hours

  validates :protocol, :external_id, :joined_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :resolution, inclusion: { in: RESOLUTIONS }, allow_nil: true

  scope :recent, -> { where(joined_at: RECENT.ago..).order(joined_at: :desc) }
  scope :pending, -> { where(resolution: nil) }

  def resolved? = resolution.present?
  # Pronto para a decisão: entrevistado e já é aparelho daqui.
  def ready? = device.present? && !resolved?
  def battery? = power_source.to_s.casecmp?("battery")

  def resolve!(resolution)
    update!(resolution: resolution, resolved_at: Time.current)
  end
end
