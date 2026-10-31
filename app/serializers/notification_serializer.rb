class NotificationSerializer < ApplicationSerializer
  attributes :id, :kind, :title, :body, :data, :read_at, :created_at
  # Lote 1 no app (F7): botões ainda respondíveis, resposta dada, link e imagem
  # (caminho relativo = no próprio servidor).
  attribute(:actions) { |n| n.responded_at ? [] : n.actions.map { |a| { id: a["id"], title: a["title"] } } }
  attributes :responded_at
  attribute(:response_title, &:response_title)
  attribute(:url, &:open_url)
  attribute(:image_url, &:image_url)
end
