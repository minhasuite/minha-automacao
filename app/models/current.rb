class Current < ActiveSupport::CurrentAttributes
  attribute :user
  # ondaA1 (A4): sistema de unidades por local, lido uma vez por requisição.
  attribute :unit_systems
end
