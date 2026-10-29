# Trilha de auditoria (padrão da suíte) nos modelos de dinheiro e conta:
# criação, exclusão e mudança dos atributos declarados viram AuditEvent.
module Auditable
  extend ActiveSupport::Concern

  included do
    class_attribute :audited_attribute_names, default: []
    after_create_commit { audit!("create") }
    after_update_commit :audit_update
    after_destroy_commit { audit!("destroy") }
  end

  class_methods do
    def audited_attributes(*names) = self.audited_attribute_names = names.map(&:to_s)
  end

  def audit!(action, details = {})
    AuditEvent.create!(tenant_id: (is_a?(Tenant) ? id : try(:tenant_id)), user_id: Current.user&.id,
                       action: action, auditable_type: self.class.name, auditable_id: id, details: details)
  rescue StandardError => e
    Rails.logger.warn("[audit] #{e.class}: #{e.message}")
  end

  private

  def audit_update
    changed = saved_changes.slice(*audited_attribute_names)
    audit!("update", changed) if changed.any?
  end
end
