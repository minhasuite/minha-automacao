module Integrations
  # Synology DSM (catalogo): NAS Synology pela Web API do DSM (login com
  # usuário e senha, sessão por chamada). CPU, memória, temperatura, tempo
  # ligado e, por volume, uso e estado. Só leitura.
  class SynologyDsmPlugin < SchemaPlugin
    describe key: "synology_dsm", title: "Synology DSM", icon: "archive",
             description: "NAS Synology pela API do DSM: uso de CPU e memória, temperatura, tempo ligado e o uso e o estado de cada volume."
    texts "pt-BR" => { points: { cpu: "CPU", memory: "Memória", volume_used: "%{name} usado", volume_ok: "%{name} com problema" },
                       fields: { otp: "Código de 2 etapas (se tiver)" }, note: "Use um usuário só para isso, sem administrador, se der: só leitura.",
                       refused: "O DSM recusou o login (código %{code})." },
          en: { title: "Synology DSM", description: "Synology NAS through the DSM API: CPU and memory use, temperature, uptime, and the usage and status of each volume.",
                points: { cpu: "CPU", memory: "Memory", volume_used: "%{name} used", volume_ok: "%{name} has a problem" },
                fields: { otp: "2-step code (if any)" }, note: "Use a dedicated non-admin user if you can: read-only.", refused: "DSM refused the login (code %{code})." },
          es: { title: "Synology DSM", description: "NAS Synology mediante la API de DSM: uso de CPU y memoria, temperatura, tiempo encendido, y el uso y el estado de cada volumen.",
                points: { cpu: "CPU", memory: "Memoria", volume_used: "%{name} usado", volume_ok: "%{name} con problema" },
                fields: { otp: "Código de 2 pasos (si tienes)" }, note: "Usa un usuario solo para esto, sin administrador, si puedes: solo lectura.",
                refused: "DSM rechazó el inicio de sesión (código %{code})." }
    field :host, required: true
    field :port, :number, default: 5001
    field :username, required: true
    field :password, secret: true, required: true
    field :otp

    class << self
      def base(integration)
        port = conf(integration, :port).to_i
        "#{port == 5000 ? 'http' : 'https'}://#{conf(integration, :host)}:#{port}/webapi"
      end

      # Uma sessão por leitura: login, as chamadas do bloco e logout.
      def session(integration)
        url = base(integration)
        q = { api: "SYNO.API.Auth", version: 3, method: "login", account: conf(integration, :username), passwd: conf(integration, :password),
              session: "MinhaAutomacao", format: "sid", otp_code: integration.settings["otp"].presence }.compact
        r = LanHttp.get("#{url}/auth.cgi?#{q.to_query}", insecure: true)
        raise Integrations.auth(Integrations::Error.new(text(:refused, code: r.dig("error", "code")))) unless r["success"]

        sid = r.dig("data", "sid")
        call = ->(api, method, version = 1, **extra) { LanHttp.get("#{url}/entry.cgi?#{{ api: api, method: method, version: version, _sid: sid, **extra }.to_query}", insecure: true)["data"].to_h }
        yield call
      ensure
        logout(url, sid) if sid
      end

      def logout(url, sid)
        LanHttp.get("#{url}/auth.cgi?#{{ api: 'SYNO.API.Auth', version: 1, method: 'logout', session: 'MinhaAutomacao', _sid: sid }.to_query}", insecure: true)
      rescue Integrations::Error
        nil
      end

      def entries(integration)
        session(integration) do |call|
          info = call.("SYNO.Core.System", "info", 1)
          vols = Array(call.("SYNO.Storage.CGI.Storage", "load_info")["volumes"])
          pts = [ point("cpu", unit: "%", state_class: "measurement"), point("memory", unit: "%", state_class: "measurement"),
                  point("temperature", unit: "°C", device_class: "temperature", state_class: "measurement"), point("uptime", unit: "h", state_class: "measurement") ] +
                vols.flat_map do |v|
                  name = v["display_name"].presence || v["id"]
                  [ point("used:#{v['id']}", name: text("points.volume_used", name: name), unit: "%", state_class: "measurement"),
                    point("bad:#{v['id']}", "problem", name: text("points.volume_ok", name: name)) ]
                end
          [ entry(id: "synology:#{info['serial'].presence || conf(integration, :host)}", name: info["model"].presence || title, manufacturer: "Synology",
                  model: info["model"], category: "DSM #{info['firmware_ver']}".strip, poll_s: 300, points: pts) ]
        end
      end

      def read(device)
        session(device.integration) do |call|
          u = call.("SYNO.Core.System.Utilization", "get")
          info = call.("SYNO.Core.System", "info", 1)
          out = { "cpu" => u.dig("cpu", "user_load").to_i + u.dig("cpu", "system_load").to_i, "memory" => u.dig("memory", "real_usage"),
                  "temperature" => info["sys_temp"], "uptime" => (info["up_time"].to_s.split(":").first(3).then { |h, m, s| h.to_i + (m.to_i / 60.0) + (s.to_i / 3600.0) }.round(1) if info["up_time"]) }
          Array(call.("SYNO.Storage.CGI.Storage", "load_info")["volumes"]).each do |v|
            total = v.dig("size", "total").to_f
            out["used:#{v['id']}"] = (v.dig("size", "used").to_f * 100 / total).round(1) if total.positive?
            out["bad:#{v['id']}"] = !%w[normal background].include?(v["status"].to_s)
          end
          out
        end
      end
    end
  end
end
