# De-para de uma migração (F10): id no sistema de origem (entidade, aparelho,
# área, automação, script, cena) → registro daqui (`target`). O importador
# resolve as entradas dos blueprints por aqui e o comparador traduz o que a
# referência fez para os pontos daqui. `target` nil = sem par (com `note`).
class ExternalRef < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :target, polymorphic: true, optional: true

  validates :source, :external_id, :kind, presence: true

  scope :mapped, -> { where.not(target_id: nil) }

  # {external_id → target_id} de uma fonte (uma consulta).
  def self.map_for(site, source, type = nil)
    scope = where(site_id: site.id, source: source).mapped
    scope = scope.where(target_type: type) if type
    scope.pluck(:external_id, :target_id).to_h
  end

  def self.link!(site, source, external_id, kind:, target: nil, name: nil, note: nil)
    ref = find_or_initialize_by(site_id: site.id, source: source, external_id: external_id)
    ref.update!(kind: kind, name: name.to_s.truncate(250).presence, target: target, note: (note unless target))
    ref
  end
end
