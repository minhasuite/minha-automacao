module Integrations
  # Importação do LocalTuya do HA (arquivo core.config_entries). Não vira card:
  # os aparelhos entram direto (Tuya::Import, idempotente pelo device_id).
  class HaImportPlugin < Plugin
    describe key: "ha_import", title: "Importar do Home Assistant", icon: "upload", driver: nil,
             description: "Traz os aparelhos Tuya que já estavam no Home Assistant, com a chave e o endereço de cada um, a partir do arquivo de configuração dele."
    texts "pt-BR" => { need_file: "Escolha o arquivo core.config_entries do Home Assistant.", imported: "Importados do HA: %{devices} dispositivo(s), %{points} ponto(s) novo(s).", bad_file: "Arquivo inválido: %{error}" },
          en: { title: "Import from Home Assistant", description: "Brings in the Tuya devices you already had in Home Assistant, with each one's key and address, from its configuration file.", need_file: "Choose the Home Assistant core.config_entries file.", imported: "Imported from HA: %{devices} device(s), %{points} new point(s).", bad_file: "Invalid file: %{error}" },
          es: { title: "Importar desde Home Assistant", description: "Trae los aparatos Tuya que ya estaban en Home Assistant, con la clave y la dirección de cada uno, desde su archivo de configuración.", need_file: "Elige el archivo core.config_entries de Home Assistant.", imported: "Importados de HA: %{devices} dispositivo(s), %{points} punto(s) nuevo(s).", bad_file: "Archivo no válido: %{error}" }

    def self.setup(site, form)
      file = form[:arquivo] or return outcome(:form, alert: text(:need_file))

      data = JSON.parse(file.read)
      r = Tuya::Import.call(site, Tuya::Import.from_config_entries(data).presence || data)
      outcome(:devices, notice: text(:imported, devices: r.devices, points: r.points))
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError => e
      outcome(:form, alert: text(:bad_file, error: e.message))
    end

    def self.reconfigurable? = false
  end
end
