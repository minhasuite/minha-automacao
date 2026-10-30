module Integrations
  # Importação do LocalTuya do HA (arquivo core.config_entries). Não vira card:
  # os aparelhos entram direto (Tuya::Import, idempotente pelo device_id).
  class HaImportPlugin < Plugin
    describe key: "ha_import", title: "Importar do Home Assistant", icon: "upload", driver: nil,
             description: "Traz os aparelhos do LocalTuya do HA (arquivo core.config_entries), com chave e IP."

    def self.setup(site, form)
      file = form[:arquivo] or return outcome(:form, alert: "Escolha o arquivo core.config_entries do Home Assistant.")

      data = JSON.parse(file.read)
      r = Tuya::Import.call(site, Tuya::Import.from_config_entries(data).presence || data)
      outcome(:devices, notice: "Importados do HA: #{r.devices} dispositivo(s), #{r.points} ponto(s) novo(s).")
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError => e
      outcome(:form, alert: "Arquivo inválido: #{e.message}")
    end

    def self.reconfigurable? = false
  end
end
