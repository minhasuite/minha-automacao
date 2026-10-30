# Leitura periódica (ESQUEMA-V1, supervisor de driver): só lê, nunca comanda.
# Dispositivo com `poll_s` > 0 (padrão 30 min; nulo ou 0 desliga) e
# integração idem. Uma leitura por vez, com `GAP` segundos entre uma e outra
# para não encher a rede. Roda numa thread do processo worker
# (on_worker_start; POLLING=off desliga); "Atualizar agora" passa pelo
# PollDeviceJob. Tuya com ouvinte ligado fica de fora (o ouvinte já lê).
module Polling
  TICK = 15
  GAP = 2
  DEVICES = { "tuya_local" => "Drivers::TuyaLocal", "xiaomi_miot" => "Drivers::XiaomiMiot" }.freeze
  # Integração de conta: varredura (`Integrations.sync!`; Alexa = lista de Echo).
  DUE = "COALESCE(poll_s, 0) > 0 AND (polled_at IS NULL OR polled_at <= now() - make_interval(secs => poll_s))".freeze

  module_function

  def supported?(device) = DEVICES.key?(device.driver)

  def start
    return if @thread&.alive?

    @thread = Thread.new do
      loop do
        run_due
        sleep TICK
      end
    end
  end

  def run_due(gap: GAP)
    ids = wrap { Device.where(driver: DEVICES.keys, disabled: false).where.not(driver: "tuya_local", listen: true).where(DUE).order(:polled_at).pluck(:id) }
    ids.each_with_index do |id, i|
      sleep gap if i.positive?
      poll_device(id)
    end
    wrap { Integration.where(driver: Integrations.drivers).where(DUE).pluck(:id) }.each { |id| poll_integration(id) }
  rescue StandardError => e
    Rails.error.report(e, handled: true)
  end

  # true = leu. Falha marca o aparelho e os pontos como indisponíveis.
  # `reconnect`: Tuya tenta as outras versões do protocolo e grava a que respondeu.
  def poll_device(id, reconnect: false)
    wrap do
      device = Device.find_by(id: id) or next false
      next false unless supported?(device)

      ActsAsTenant.with_tenant(device.tenant) do
        device.update_columns(polled_at: Time.current)
        driver = DEVICES.fetch(device.driver).constantize
        reconnect && driver.respond_to?(:reconnect) ? driver.reconnect(device) : driver.poll(device)
        device.update_columns(last_error: nil) if device.last_error
        true
      rescue StandardError => e
        Rails.logger.warn("[polling] #{device.name}: #{e.class}: #{e.message}")
        device.update_columns(last_error: "#{l_now} #{e.message}".truncate(255))
        driver.unavailable!(device)
        false
      end
    end
  end

  def poll_integration(id)
    wrap do
      integration = Integration.find_by(id: id) or next false
      ActsAsTenant.with_tenant(integration.tenant) do
        integration.update_columns(polled_at: Time.current)
        Integrations.sync!(integration)
        true
      rescue StandardError => e # o próprio sync! grava o erro na integração
        Rails.logger.warn("[polling] #{integration.name}: #{e.message}")
        false
      end
    end
  end

  def l_now = I18n.l(Time.current, format: :short)

  def wrap(&) = Rails.application.executor.wrap { ActsAsTenant.without_tenant(&) }
end
