# Espera a confirmação do QR da Xiaomi (até ~5 min numa requisição só).
# Roda numa thread própria do worker: o job sai na hora e não segura a fila
# (JOB_CONCURRENCY=1, ouvintes Tuya/MQTT no mesmo processo). Se o worker
# cair no meio, a tela vê o QR vencido por `qr_until` e pede outro.
class XiaomiQrLoginJob < ApplicationJob
  queue_as :default

  def perform(integration_id)
    Thread.new { self.class.wait(integration_id) }
  end

  def self.wait(integration_id)
    Polling.wrap do
      integration = Integration.find_by(id: integration_id) or next
      ActsAsTenant.with_tenant(integration.tenant) { wait_for(integration) }
    end
  end

  def self.wait_for(integration)
    lp = integration.secrets["lp"] or return
    Rails.logger.info("[xiaomi] QR #{integration.id}: esperando a confirmação no app")
    Miio::Cloud.new(integration).qr_wait
    Rails.logger.info("[xiaomi] QR #{integration.id}: confirmado, procurando os aparelhos")
    Integrations.start_sync!(integration)
  rescue Integrations::Error => e
    Rails.logger.warn("[xiaomi] QR #{integration.id}: #{e.message}")
    Miio::Cloud.new(integration.reload).qr_failed!(lp, e.message)
  end
end
