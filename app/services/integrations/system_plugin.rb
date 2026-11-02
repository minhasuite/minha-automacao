require "open3"

module Integrations
  # Sistema (Lote 4, G19; os sensores de disco, backup, integrações e
  # automações do HA): o próprio servidor como pontos de um aparelho virtual,
  # para gatilhos, alertas, consultas e painéis de manutenção. Medida nova =
  # uma entrada em `METRICS` (campo → atributos do ponto + leitura); medida sem
  # leitura neste servidor (ex.: sem pasta de backup) não cria ponto. Lê a cada
  # 5 min (a varredura da integração).
  class SystemPlugin < Plugin
    describe key: "system", title: "Sistema", icon: "cog",
             description: "Disco, último backup, integrações com erro, automações que falharam e pontos sem sinal, como pontos."
    texts "pt-BR" => { added: "Sistema adicionado: %{n} pontos." },
          en: { title: "System", description: "Disk, last backup, integrations with errors, failed automations and points with no signal, as points.", added: "System added: %{n} points." },
          es: { title: "Sistema", description: "Disco, último respaldo, integraciones con error, automatizaciones que fallaron y puntos sin señal, como puntos.", added: "Sistema agregado: %{n} puntos." }

    POLL_S = 5 * 60
    BACKUP_LATE = 26.hours

    METRICS = {
      "disk_used" => { name: "Disco usado", capability: "measure", unit: "%", read: ->(_site) { SystemPlugin.disk&.dig(:used) } },
      "disk_free" => { name: "Disco livre", capability: "measure", unit: "GB", read: ->(_site) { SystemPlugin.disk&.dig(:free) } },
      "backup_at" => { name: "Último backup", capability: "datetime", read: ->(_site) { SystemPlugin.last_backup&.iso8601 } },
      "backup_late" => { name: "Backup atrasado", capability: "problem", device_class: "problem",
                         read: ->(_site) { (at = SystemPlugin.last_backup) && at < BACKUP_LATE.ago } },
      # G20: só com a cópia externa configurada (sem ela, não cria o ponto).
      "offsite_backup_late" => { name: "Backup externo atrasado ou com falha", capability: "problem", device_class: "problem",
                                 read: ->(_site) { !Backups.offsite_ok? if Backups.configured? } },
      "integrations_error" => { name: "Integrações com erro", capability: "measure", read: ->(site) { site.integrations.where(status: "error").count } },
      "integrations_error_names" => { name: "Integrações com erro (nomes)", capability: "text",
                                      read: ->(site) { site.integrations.where(status: "error").order(:name).pluck(:name).join(", ") } },
      "automations_on" => { name: "Automações ligadas", capability: "measure", read: ->(site) { site.automations.where(enabled: true).count } },
      "runs_24h" => { name: "Execuções em 24 h", capability: "measure", read: ->(site) { SystemPlugin.runs(site).count } },
      "failed_24h" => { name: "Falhas em 24 h", capability: "measure", read: ->(site) { SystemPlugin.runs(site).where(status: "failed").count } },
      "running" => { name: "Execuções em andamento", capability: "measure", read: ->(site) { AutomationRun.active.where(site_id: site.id).count } },
      "points_unavailable" => { name: "Pontos sem sinal", capability: "measure",
                                read: ->(site) { site.points.where(quality: "unavailable", disabled: false, hidden: false).count } }
    }.freeze

    def self.setup(site, _form)
      integration = site.integrations.find_or_create_by!(driver: driver) { |i| i.assign_attributes(name: title, poll_s: POLL_S) }
      integration.update!(settings: integration.settings.merge("account" => "Este servidor"))
      Integrations.sync!(integration)
      outcome(:index, notice: text(:added, n: device_for(integration).points.count))
    end

    def self.reconfigurable? = false
    def self.custom_sync? = true

    def self.sync!(integration)
      site = integration.site
      device = device_for(integration)
      METRICS.each do |field, m|
        value = m[:read].call(site)
        next if value.nil?

        point = device.points.find_by("address->>'field' = ?", field) ||
                device.points.create!(site: site, name: m[:name], capability: m[:capability], unit: m[:unit], device_class: m[:device_class],
                                      history: "on_change", address: { "field" => field }, key: Integrations.unique_key(site, device, m[:name]))
        point.report!(value)
      end
      device.update_columns(last_seen_at: Time.current)
      integration.ok!
      { found: 1, fresh: 0, removed: 0, keys: 0 }
    end

    def self.device_for(integration)
      integration.site.devices.find_or_create_by!(driver: "virtual", external_id: "system:#{integration.id}") do |d|
        d.name = integration.name
        d.integration = integration
        d.manufacturer = "Minha Automação"
      end
    end

    def self.runs(site) = AutomationRun.real.where(site_id: site.id, created_at: 24.hours.ago..)

    # {used: %, free: GB} do disco onde roda o app (df do sistema); nil se não der.
    def self.disk(path = Rails.root.to_s)
      out, status = Open3.capture2("df", "-Pk", path)
      cols = out.lines.last.to_s.split
      return unless status.success? && cols.size >= 5

      { used: cols[4].to_i, free: (cols[3].to_f / 1024 / 1024).round(1) }
    rescue SystemCallError
      nil
    end

    # Arquivo mais novo da pasta de backup (`BACKUP_DIR`; no servidor da casa, /backups).
    def self.last_backup(dir = ENV.fetch("BACKUP_DIR", "/backups"))
      files = Dir.glob(File.join(dir, "*")).select { |f| File.file?(f) && !f.end_with?(".tmp") }
      files.map { |f| File.mtime(f) }.max&.in_time_zone
    end
  end
end
