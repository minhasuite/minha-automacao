# Área do local, hierárquica (andar → cômodo; linha → célula).
class Area < ApplicationRecord
  include Auditable
  include Labelable
  include Aliasable

  acts_as_tenant :tenant

  KINDS = LocalizedLabel.for("labels.area_kinds", %w[room floor outdoor line cell warehouse])

  belongs_to :site
  belongs_to :parent, class_name: "Area", optional: true
  has_many :devices, dependent: nil # nullify no banco
  has_many :points, dependent: nil

  validates :name, presence: true
  validates :level, numericality: { only_integer: true, in: -10..200 }, allow_nil: true
  validates :kind, inclusion: { in: KINDS.keys }
  validate :parent_in_same_site

  normalizes :name, with: ->(v) { v.to_s.squish }

  audited_attributes :name

  def kind_label = KINDS.fetch(kind, kind)
  def floor? = kind == "floor"

  # ondaA1 (A1): o andar da área (ela mesma, se for andar, ou o primeiro
  # andar acima na hierarquia). `by_id`: as áreas do local já carregadas.
  def floor_area(by_id = site.areas.index_by(&:id))
    seen = Set.new
    a = self
    while a && seen.add?(a.id)
      return a if a.floor?

      a = by_id[a.parent_id]
    end
  end

  # A área e todas as de dentro (andar → ala → cômodo), para mirar por andar.
  def subtree_ids = self.class.subtree_ids(site.areas.pluck(:id, :parent_id), id)

  def self.subtree_ids(pairs, root)
    children = pairs.group_by(&:last)
    ids = Set[root]
    queue = [ root ]
    while (id = queue.shift)
      Array(children[id]).each { |(child, _)| queue << child if ids.add?(child) }
    end
    ids
  end

  # "Térreo", "1º andar", "Subsolo 1" quando o andar não tem nome próprio de nível.
  def level_label
    return if level.nil?
    return "Térreo" if level.zero?

    level.negative? ? "Subsolo #{-level}" : "#{level}º andar"
  end

  private

  def parent_in_same_site
    return unless parent

    errors.add(:parent, :other_site) if parent.site_id != site_id || parent_id == id
  end
end
