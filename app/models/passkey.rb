# Passkey (WebAuthn) de uma pessoa (ondaA2 A16; Passkeys). Sem tenant: o
# login acha a passkey antes de saber de quem é.
class Passkey < ApplicationRecord
  belongs_to :user

  validates :name, :credential_id, :public_key, presence: true
  validates :credential_id, uniqueness: true
end
