module Diagnostics
  # Reparos seguros (registro em `Diagnostics::FIXES`).
  module Fixes
    # IP novo que a varredura da conta já conhece (DHCP trocou): grava no cadastro.
    class ApplyIp < Fix
      describe key: "apply_ip", label: "Usar o IP novo", icon: "refresh"
      texts "pt-BR" => { done: "%{name}: IP atualizado para %{host}.", none: "A conta não traz outro IP para este aparelho." },
            en: { label: "Use the new IP", done: "%{name}: IP updated to %{host}.", none: "The account has no other IP for this device." },
            es: { label: "Usar la IP nueva", done: "%{name}: IP actualizada a %{host}.", none: "La cuenta no trae otra IP para este dispositivo." }
      ACTION = "device.ip_update".freeze

      def self.new_host(device)
        return nil unless device&.integration && device.external_id.present?

        e = device.integration.found.find { |x| x["id"].to_s == device.external_id.to_s } or return nil
        host = e.dig("address", "host").presence
        host if host && host != device.address.to_h["host"]
      end

      def self.available?(finding, _ctx) = new_host(finding.device).present?

      def self.call(finding, user:, params: {})
        device = finding.device
        host = new_host(device) or raise Error, text(:none)
        before = device.address.to_h["host"]
        device.update!(address: device.address.to_h.merge("host" => host))
        AuditEvent.create!(tenant_id: device.tenant_id, user_id: user&.id, action: ACTION, auditable_type: "Device", auditable_id: device.id,
                           details: { "from" => before, "to" => host })
        text(:done, name: device.name, host: host)
      end
    end

    # Uma leitura pela fila tentando as versões do protocolo (só leitura, como o "Reconectar" da página).
    class Reconnect < Fix
      describe key: "reconnect", label: "Reconectar", icon: "refresh", role: :command
      texts "pt-BR" => { done: "%{name}: reconexão pedida (só leitura)." },
            en: { label: "Reconnect", done: "%{name}: reconnection requested (read only)." },
            es: { label: "Reconectar", done: "%{name}: reconexión solicitada (solo lectura)." }

      def self.available?(finding, _ctx) = finding.device&.removed_at.nil? && finding.device && Polling.supported?(finding.device)

      def self.call(finding, user:, params: {})
        PollDeviceJob.perform_later(finding.device.id, reconnect: true)
        text(:done, name: finding.device.name)
      end
    end

    # Varre a conta de novo (o "Sincronizar agora" da integração): traz IP, chave e pontos.
    class Scan < Fix
      describe key: "scan", label: "Varrer a conta", icon: "search"
      texts "pt-BR" => { done: "%{name}: varredura pedida." },
            en: { label: "Scan the account", done: "%{name}: scan requested." },
            es: { label: "Escanear la cuenta", done: "%{name}: escaneo solicitado." }

      def self.available?(finding, _ctx) = finding.integration&.plugin.present?

      def self.call(finding, user:, params: {})
        ::Integrations.start_sync!(finding.integration)
        text(:done, name: finding.integration.name)
      end
    end

    # Login vencido ou endereço errado da conta: o assistente da integração.
    class Reconfigure < Fix
      describe key: "reconfigure", label: "Reconfigurar a integração", icon: "link", kind: :link
      texts en: { label: "Reconfigure the integration" }, es: { label: "Reconfigurar la integración" }

      def self.available?(finding, _ctx) = finding.integration&.plugin&.reconfigurable? ? true : false
      def self.url(finding) = routes.connect_integration_path(finding.integration)
    end

    # Parear de novo (Zigbee): a tela do assistente de pareamento, quando a
    # rota existe (`pair_route` no config/device_diagnostics.yml).
    class Pair < Fix
      describe key: "pair", label: "Parear de novo", icon: "plus-circle", kind: :link
      texts en: { label: "Pair again" }, es: { label: "Emparejar de nuevo" }

      def self.route = Diagnostics.config["pair_route"].presence

      def self.available?(finding, _ctx)
        d = finding.device
        !!(d && route && routes.respond_to?("#{route}_path") && Array(Diagnostics.config["pair_drivers"]).include?(d.driver))
      end

      # `pair_params` completa a rota (ex.: o protocolo); o aparelho vai junto como `device_id`.
      def self.url(finding)
        extra = Diagnostics.config["pair_params"].to_h.transform_keys(&:to_sym)
        routes.public_send("#{route}_path", site_id: finding.site_id, device_id: finding.device.id, **extra)
      end
    end

    # "Substituir aparelho" (Devices::Replace): os pontos passam para o aparelho novo.
    class Replace < Fix
      describe key: "replace", label: "Substituir aparelho", icon: "switch-horizontal", kind: :link
      texts en: { label: "Replace device" }, es: { label: "Reemplazar dispositivo" }

      def self.available?(finding, _ctx) = finding.device.present? && Devices::Replace.candidates(finding.device).exists?
      def self.url(finding) = routes.replace_device_path(finding.device)
    end

    class SetArea < Fix
      describe key: "set_area", label: "Definir área", icon: "home", kind: :form
      texts "pt-BR" => { done: "%{name} agora está em %{area}.", pick: "Escolha a área." },
            en: { label: "Set area", done: "%{name} is now in %{area}.", pick: "Choose the area." },
            es: { label: "Definir área", done: "%{name} ahora está en %{area}.", pick: "Elige el área." }

      def self.available?(finding, _ctx) = finding.device.present? && finding.device.site.areas.exists?
      def self.options(finding, _ctx) = finding.device.site.areas.order(:name).map { |a| [ a.name, a.id ] }

      def self.call(finding, user:, params: {})
        device = finding.device
        area = device.site.areas.find_by(id: params[:area_id]) or raise Error, text(:pick)
        device.update!(area: area)
        text(:done, name: device.name, area: area.name)
      end
    end

    # Cadastro (IP, RTSP, versão): a edição do aparelho.
    class Edit < Fix
      describe key: "edit", label: "Editar cadastro", icon: "pencil", kind: :link
      texts en: { label: "Edit details" }, es: { label: "Editar registro" }

      def self.available?(finding, _ctx) = finding.device.present?
      def self.url(finding) = routes.edit_device_path(finding.device)
    end

    # Apagar cadastro órfão (sumiu da conta, sem pontos, duplicado). Confirma
    # e guarda um AuditEvent com o que era (nome, driver, external_id, pontos).
    class DeleteDevice < Fix
      describe key: "delete_device", label: "Apagar cadastro", icon: "trash", confirm: true, danger: true
      texts "pt-BR" => { done: "%{name}: cadastro apagado.", confirm: "Apagar o cadastro de %{name}? Os %{n} ponto(s) e o histórico dele saem junto." },
            en: { label: "Delete record", done: "%{name}: record deleted.", confirm: "Delete %{name}'s record? Its %{n} point(s) and history go with it." },
            es: { label: "Borrar registro", done: "%{name}: registro borrado.", confirm: "¿Borrar el registro de %{name}? Sus %{n} punto(s) y el historial se van con él." }
      ACTION = "device.orphan_delete".freeze

      def self.available?(finding, _ctx) = finding.device.present?
      def self.confirm_text(finding) = text(:confirm, name: finding.device.name, n: finding.device.points.count)

      def self.call(finding, user:, params: {})
        d = finding.device
        details = { "rule" => finding.rule.key, "name" => d.name, "driver" => d.driver, "external_id" => d.external_id,
                    "integration_id" => d.integration_id, "area_id" => d.area_id, "points" => d.points.pluck(:key) }
        Device.transaction do
          AuditEvent.create!(tenant_id: d.tenant_id, user_id: user&.id, action: ACTION, auditable_type: "Device", auditable_id: d.id, details: details)
          d.destroy!
        end
        text(:done, name: d.name)
      end
    end
  end
end
