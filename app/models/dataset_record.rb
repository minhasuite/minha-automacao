# Uma linha de um conjunto de dados (Lote 2): `data` jsonb, `created_at`.
class DatasetRecord < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :dataset

  # Linha para resposta de ação, tela e CSV: {id, em, ...campos}.
  def row(zone = Time.zone) = { "id" => id, "em" => created_at.in_time_zone(zone).iso8601 }.merge(data)
end
