# Linha da trilha de auditoria. Global (sem acts_as_tenant): grava inclusive
# quando a empresa está sendo apagada; tenant_id é só para filtrar.
class AuditEvent < ApplicationRecord
  belongs_to :tenant, optional: true

  # Entrada de alguém (web ou app): o Diário mostra para o dono do local.
  def self.login!(user, via)
    create!(tenant_id: user.tenant_id, user_id: user.id, action: "login", auditable_type: "User", auditable_id: user.id, details: { via: via })
  rescue StandardError => e
    Rails.logger.warn("[audit] #{e.class}: #{e.message}")
  end
end
