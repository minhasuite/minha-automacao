class Current < ActiveSupport::CurrentAttributes
  attribute :user
  # ondaA1 (A4): sistema de unidades por local, lido uma vez por requisição.
  attribute :unit_systems
  # ondaB2 (B11): o tema da pessoa (aparelho ou perfil), por cima do tema do painel.
  attribute :theme_key
end
