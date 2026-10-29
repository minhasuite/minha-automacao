# Convite para entrar na empresa, por CÓDIGO (sem e-mail: SMTP é opcional).
# Quem convida recebe o código na tela e manda pela conversa. Vale 7 dias e
# uma vez só; guardamos só o digest.
class Invite < ApplicationRecord
  acts_as_tenant :tenant
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :accepted_by, class_name: "User", optional: true

  TTL = 7.days
  # Sem 0/O/1/I: o código é digitado à mão.
  ALPHABET = ((("A".."Z").to_a + ("2".."9").to_a) - %w[O I]).freeze
  LENGTH = 10

  validates :role, inclusion: { in: User::ROLES - %w[owner] }

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(code) = Digest::SHA256.hexdigest(code.to_s.strip.upcase.delete("-"))

  # => [convite, código em claro] — a única vez que o código existe fora do digest.
  def self.generate!(created_by:, role: "member")
    code = Array.new(LENGTH) { ALPHABET.sample(random: SecureRandom) }.join
    [ create!(created_by: created_by, role: role, code_digest: digest(code), expires_at: TTL.from_now), code ]
  end

  # Busca sem tenant: quem aceita ainda está na própria empresa.
  def self.find_valid(code)
    ActsAsTenant.without_tenant { pending.find_by(code_digest: digest(code)) }
  end
end
