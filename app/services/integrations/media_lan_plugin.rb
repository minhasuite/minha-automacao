module Integrations
  # Base dos plugins de mídia da rede (Pacote 1): erro de rede vira
  # Integrations::Error e, depois da varredura e da adoção, lê o estado.
  class MediaLanPlugin < LanPlugin
    def self.inventory(integration)
      super
    rescue *Drivers::MediaLan::NET => e
      raise Integrations::Error, e.message
    end

    def self.refresh(integration)
      integration.devices.where(driver: driver, removed_at: nil, disabled: false).find_each do |device|
        Drivers::REGISTRY.fetch(driver).constantize.poll(device)
      rescue StandardError => e
        Rails.logger.warn("[#{key}] estado de #{device.name}: #{e.message}")
      end
    end
  end
end
