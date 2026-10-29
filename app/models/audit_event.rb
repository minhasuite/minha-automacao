# Linha da trilha de auditoria. Global (sem acts_as_tenant): grava inclusive
# quando a empresa está sendo apagada; tenant_id é só para filtrar.
class AuditEvent < ApplicationRecord
  belongs_to :tenant, optional: true
end
