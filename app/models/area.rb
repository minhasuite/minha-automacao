# Área do local, hierárquica (andar → cômodo; linha → célula).
class Area < ApplicationRecord
  include Auditable

  acts_as_tenant :tenant

  KINDS = LocalizedLabel.for("labels.area_kinds", %w[room floor outdoor line cell warehouse])

  belongs_to :site
  belongs_to :parent, class_name: "Area", optional: true
  has_many :devices, dependent: nil # nullify no banco
  has_many :points, dependent: nil

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS.keys }
  validate :parent_in_same_site

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name

  def kind_label = KINDS.fetch(kind, kind)

  private

  def parent_in_same_site
    return unless parent

    errors.add(:parent, :other_site) if parent.site_id != site_id || parent_id == id
  end
end
