# Alerta in-app. Com `user` vai só para a pessoa (push nos aparelhos dela);
# sem `user` vai para os administradores da empresa. O push FCM sai pelo Notifier.
# `dedup_key` impede repetir o mesmo alerta.
class Notification < ApplicationRecord
  acts_as_tenant :tenant
  belongs_to :user, optional: true

  KINDS = %w[convite resumo_diario sistema aviso alerta].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  # O que esta pessoa vê no sino: o que é dela e, se for admin, o da empresa.
  scope :for_user, ->(u) { u.admin? ? where(user_id: [ u.id, nil ]) : where(user_id: u.id) }
end
