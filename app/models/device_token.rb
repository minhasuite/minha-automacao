# Token FCM de um aparelho (push nativo). Não é tenant-scoped: o push roda em
# background e chega pelo usuário.
class DeviceToken < ApplicationRecord
  belongs_to :user

  PLATFORMS = %w[android ios].freeze

  validates :token, presence: true, uniqueness: true
  validates :platform, inclusion: { in: PLATFORMS }
end
