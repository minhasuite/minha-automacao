# Local: casa, loja ou fábrica (ESQUEMA-V1 §4.1). Dono e administradores da
# empresa são donos de todos os locais; os demais entram por SiteMembership.
class Site < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  KINDS = { "home" => "Casa", "store" => "Loja", "plant" => "Fábrica" }.freeze

  has_many :areas, dependent: nil # cascade no banco
  has_many :devices, dependent: nil
  has_many :points, dependent: nil
  has_many :memberships, class_name: "SiteMembership", dependent: nil
  has_many :point_links, dependent: nil
  has_many :scenes, dependent: nil
  has_many :schedules, dependent: nil
  has_many :notify_rules, dependent: nil
  has_many :alert_rules, dependent: nil
  has_many :alerts, dependent: nil
  has_many :dashboards, dependent: nil
  has_many :automations, dependent: nil
  has_many :integrations, dependent: nil

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS.keys }
  validates :timezone, inclusion: { in: ActiveSupport::TimeZone::MAPPING.values }
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name

  # Locais que a pessoa vê (membro com acesso válido, ou admin da empresa).
  def self.visible_to(user)
    return all if user.admin?

    where(id: SiteMembership.active.where(user_id: user.id).select(:site_id))
  end

  # Papel da pessoa no local (nil = sem acesso).
  def role_for(user)
    return "owner" if user.admin?

    memberships.active.find_by(user_id: user.id)&.role
  end

  def kind_label = KINDS.fetch(kind, kind)
end
