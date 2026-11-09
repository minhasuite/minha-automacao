require "etc"
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
    STARTED_AT = Time.current
    SYS = ENV.fetch("HOST_SYS", "/sys")
    BACKUP_LATE = 26.hours
    BACKUP_EVERY = 24.hours

    METRICS = {
      "disk_used" => { name: "Disco usado", capability: "measure", unit: "%", read: ->(_site) { SystemPlugin.disk&.dig(:used) } },
      "disk_free" => { name: "Disco livre", capability: "measure", unit: "GB", read: ->(_site) { SystemPlugin.disk&.dig(:free) } },
      # hassio do HA (CPU e memória do Core): a carga do servidor e a memória em uso.
      "cpu" => { name: "Processador", capability: "measure", unit: "%", read: ->(_site) { SystemPlugin.cpu } },
      "memory" => { name: "Memória usada", capability: "measure", unit: "%", read: ->(_site) { SystemPlugin.memory } },
      # update do HA: versão nova do Minha Automação no canal escolhido (só onde dá para atualizar).
      "update_available" => { name: "Atualização disponível", capability: "problem", device_class: "update",
                              read: ->(_site) { Updates.available?(Updates.latest) if Updates.supported? } },
      # update do HA com `installed_version` (os tiles "Core" e "Sistema"): a versão instalada do Minha
      # Automação e o kernel do servidor (o contêiner divide o kernel com a máquina; o resto do sistema é da imagem).
      "app_version" => { name: "Versão do Minha Automação", capability: "text", read: ->(_site) { SystemPlugin.app_version } },
      "kernel" => { name: "Sistema do servidor", capability: "text", read: ->(_site) { SystemPlugin.kernel } },
      "backup_at" => { name: "Último backup", capability: "datetime", read: ->(_site) { SystemPlugin.last_backup&.iso8601 } },
      # backup do HA (próximo agendado e o estado do gerenciador): o local roda 24 h depois do anterior.
      "backup_next" => { name: "Próximo backup", capability: "datetime", read: ->(_site) { (SystemPlugin.last_backup + BACKUP_EVERY).iso8601 if SystemPlugin.last_backup } },
      "backup_state" => { name: "Estado do backup", capability: "text", read: ->(_site) { SystemPlugin.backup_state } },
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
                                read: ->(site) { site.points.where(quality: "unavailable", disabled: false, hidden: false).count } },
      # resto (uptime do HA): desde quando o servidor e o Minha Automação estão no ar.
      "host_up_since" => { name: "Servidor ligado desde", capability: "datetime", read: ->(_site) { SystemPlugin.booted_at&.iso8601 } },
      "app_up_since" => { name: "Minha Automação no ar desde", capability: "datetime", read: ->(_site) { STARTED_AT.iso8601 } },
      # resto (raspberry_pi / rpi_power do HA): placa e falta de energia na fonte, só no Raspberry Pi.
      "board" => { name: "Placa", capability: "text", read: ->(_site) { SystemPlugin.board } },
      "undervoltage" => { name: "Fonte fraca (subtensão)", capability: "problem", device_class: "problem", read: ->(_site) { SystemPlugin.undervoltage } }
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
                                      history: "on_change", address: { "field" => field }, key: Integrations.unique_key(site, device, m[:name]),
                                      writable: false)
        point.update_columns(writable: false) if point.writable # leitura do servidor: data e texto não viram campo de editar
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

    # Carga do último minuto sobre o número de núcleos, em % (0–100); nil se não der.
    def self.cpu(loadavg = "/proc/loadavg")
      (File.read(loadavg).split.first.to_f / Etc.nprocessors * 100).round.clamp(0, 100)
    rescue SystemCallError
      nil
    end

    # Memória em uso (total − disponível), em %; nil se não der.
    def self.memory(meminfo = "/proc/meminfo")
      kb = File.read(meminfo).scan(/^(MemTotal|MemAvailable):\s+(\d+)/).to_h.transform_values(&:to_f)
      return nil unless kb["MemTotal"].to_f.positive? && kb["MemAvailable"]

      ((1 - (kb["MemAvailable"] / kb["MemTotal"])) * 100).round
    rescue SystemCallError
      nil
    end

    # Tag da imagem (ou a release gravada pelo CI) e o commit, como em Configurações → Sistema.
    def self.app_version
      [ Updates.current_tag, ("(#{Updates.current_commit})" if Updates.current_commit) ].compact.join(" ").presence
    end

    # "Linux 6.12.96+deb13-amd64": o kernel da máquina (nil se não der para ler).
    def self.kernel(osrelease = "/proc/sys/kernel/osrelease")
      v = File.read(osrelease).strip.presence
      "Linux #{v}" if v
    rescue SystemCallError
      nil
    end

    def self.booted_at(uptime = "/proc/uptime")
      s = File.read(uptime).to_f
      (Time.current - s).change(sec: 0) if s.positive?
    rescue SystemCallError
      nil
    end

    # Modelo da placa pela árvore de dispositivos (Raspberry Pi, Orange Pi…); nil num PC.
    def self.board(sys = SYS)
      File.read("#{sys}/firmware/devicetree/base/model").delete("\0").strip.presence
    rescue SystemCallError
      nil
    end

    # Raspberry Pi: o hwmon `rpi_volt` acende `in0_lcrit_alarm` quando a fonte não dá conta (como o rpi_power do HA).
    def self.undervoltage(sys = SYS)
      dir = Dir["#{sys}/class/hwmon/hwmon*"].find { |d| File.read("#{d}/name").strip == "rpi_volt" rescue false } or return nil # rubocop:disable Style/RescueModifier
      File.read("#{dir}/in0_lcrit_alarm").strip == "1"
    rescue SystemCallError
      nil
    end

    # Em dia, atrasado ou com falha (a cópia externa, quando configurada, também conta); nil sem pasta de backup.
    def self.backup_state
      at = last_backup or return nil
      return "Atrasado" if at < BACKUP_LATE.ago
      return "Cópia externa com falha" if Backups.configured? && !Backups.offsite_ok?

      "Em dia"
    end

    # Arquivo mais novo da pasta de backup (`BACKUP_DIR`; no servidor da casa, /backups).
    def self.last_backup(dir = ENV.fetch("BACKUP_DIR", "/backups"))
      files = Dir.glob(File.join(dir, "*")).select { |f| File.file?(f) && !f.end_with?(".tmp") }
      files.map { |f| File.mtime(f) }.max&.in_time_zone
    end
  end
end
