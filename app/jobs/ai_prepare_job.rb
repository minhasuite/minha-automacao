# "Conectar" de um aplicativo de IA (Configurações → Aplicativos): o provedor
# prepara o que precisa fora da tela (Ollama: baixar o modelo, que demora).
# Erro fica na conta (`last_error`), como no "Testar conexão".
class AiPrepareJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    ActsAsTenant.without_tenant do
      account = AiAccount.find_by(id: account_id) or return
      ActsAsTenant.with_tenant(account.tenant) do
        account.plugin.prepare(account)
        account.update!(last_ok_at: Time.current, last_error: nil)
      rescue Ai::Client::Error => e
        account.update!(last_error: e.message.truncate(200))
      end
    end
  end
end
