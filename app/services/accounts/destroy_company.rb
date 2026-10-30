module Accounts
  # Apaga a empresa inteira (último membro saiu ou excluiu a conta).
  module DestroyCompany
    module_function

    def call(tenant)
      ActsAsTenant.with_tenant(tenant) do
        WipeData.call(tenant)
        [ AiUsage, AiCall, AiAccount, Invite ].each(&:delete_all)
      end
      AuditEvent.where(tenant_id: tenant.id).delete_all
      User.where(tenant_id: tenant.id).find_each(&:destroy!)
      tenant.delete
      # Fora da empresa: o job levaria o tenant apagado (acts_as_tenant serializa o atual).
      ActsAsTenant.with_tenant(nil) { LicencasDeleteJob.perform_later(tenant.id) }
    end
  end
end
