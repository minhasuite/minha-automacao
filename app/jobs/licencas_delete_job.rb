# Empresa excluída (LGPD): o licenciamento central apaga o dono e as assinaturas dele.
class LicencasDeleteJob < ApplicationJob
  queue_as :default

  def perform(tenant_id) = Licencas::Client.delete_owner(tenant_id)
end
