module Accounts
  # Apaga a empresa inteira (último membro saiu ou excluiu a conta).
  module DestroyCompany
    module_function

    def call(tenant)
      ActsAsTenant.with_tenant(tenant) do
        WipeData.call(tenant)
        [ AiCall, AiAccount, Invite ].each(&:delete_all)
      end
      AuditEvent.where(tenant_id: tenant.id).delete_all
      User.where(tenant_id: tenant.id).find_each(&:destroy!)
      tenant.delete
    end
  end
end
