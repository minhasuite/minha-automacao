# Satélite de voz (ondaB1, B6): um aparelho com microfone numa área, do tipo
# de Assist::Satellites (Wyoming pelo endereço, ESPHome pelo aparelho já
# integrado), com pipeline (vazio = o preferido do local) e o papel com que
# a voz dele comanda (no máximo morador; crítico nunca por voz).
class AssistSatellite < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :area, optional: true
  belongs_to :pipeline, class_name: "AssistPipeline", optional: true
  belongs_to :device, optional: true

  ROLES = SiteMembership::ROLES.first(SiteMembership::ROLES.index("resident") + 1).freeze
  ONLINE = 2.minutes

  validates :name, presence: true, length: { maximum: 60 }, uniqueness: { scope: :site_id }
  validates :kind, inclusion: { in: ->(_) { Assist::Satellites.plugins.map(&:key) } }
  validates :role, inclusion: { in: ROLES }
  validates :host, presence: true, format: { with: Assist::Engines::WyomingServer::HOST }, if: -> { plugin&.needs&.include?(:host) }
  validates :port, numericality: { only_integer: true, in: 1..65_535 }, allow_nil: true
  validates :device, presence: true, if: -> { plugin&.needs&.include?(:device) }
  validate :same_site

  normalizes :name, :host, with: ->(v) { v.to_s.strip.presence }

  def plugin = Assist::Satellites[kind]
  def pipeline_or_default = pipeline || AssistPipeline.for(site)
  def online? = last_seen_at.present? && last_seen_at > ONLINE.ago
  def seen! = update_columns(last_seen_at: Time.current, last_error: nil)

  private

  def same_site
    errors.add(:area, :invalid) if area && area.site_id != site_id
    errors.add(:pipeline, :invalid) if pipeline && pipeline.site_id != site_id
    errors.add(:device, :invalid) if device && device.site_id != site_id
  end
end
