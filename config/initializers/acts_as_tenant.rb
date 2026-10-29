# Toda query em modelo tenant-scoped exige a empresa atual: sem tenant, levanta
# ActsAsTenant::Errors::NoTenantSet em vez de rodar sem escopo (vazaria dados
# de todas as empresas). Jobs e scripts usam ActsAsTenant.with_tenant(...).

ActsAsTenant.configure do |config|
  config.require_tenant = true
end
