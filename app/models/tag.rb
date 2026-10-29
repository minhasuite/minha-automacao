# Etiqueta (o label `iluminacao` de hoje) em ponto, dispositivo ou área.
class Tag < ApplicationRecord
  acts_as_tenant :tenant

  has_many :taggings, dependent: nil # cascade no banco

  validates :name, presence: true, uniqueness: { scope: :tenant_id }
  normalizes :name, with: ->(v) { v.to_s.squish.downcase }
end
