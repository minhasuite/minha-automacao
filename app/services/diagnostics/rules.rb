module Diagnostics
  # Regras do diagnóstico (registro em `Diagnostics::RULES`). Cada uma diz se
  # vale para o sujeito, o motivo provável, a severidade e os reparos.
  module Rules
    # Conta/coordenador/servidor da integração com erro e vários aparelhos dela
    # sem sinal juntos: um achado na integração, no lugar de um por aparelho.
    class IntegrationDown < Rule
      describe key: "integration_down", label: "Integração fora", subject: :integration, severity: "error", icon: "link",
               description: "A conta, o coordenador ou o servidor da integração está com erro e os aparelhos dela caíram juntos."
      texts "pt-BR" => { reason: "Os aparelhos caíram juntos: o problema é a integração (login vencido, coordenador ou servidor fora), não cada aparelho.",
                         detail: "%{n} aparelho(s) sem sinal · %{error}" },
            en: { label: "Integration down", description: "The integration's account, coordinator or server is failing and its devices dropped together.",
                  reason: "The devices dropped together: the problem is the integration (expired login, coordinator or server down), not each device.",
                  detail: "%{n} device(s) offline · %{error}" },
            es: { label: "Integración caída", description: "La cuenta, el coordinador o el servidor de la integración tiene error y sus dispositivos cayeron juntos.",
                  reason: "Los dispositivos cayeron juntos: el problema es la integración (sesión vencida, coordinador o servidor caído), no cada dispositivo.",
                  detail: "%{n} dispositivo(s) sin señal · %{error}" }

      def self.applies?(integration, ctx) = ctx.integration_down?(integration)
      def self.fixes(_integration, _ctx) = %w[reconfigure scan]

      def self.finding(integration, ctx)
        n = ctx.active_devices.count { |d| d.integration_id == integration.id && ctx.offline?(d) }
        super(integration, ctx, detail: text(:detail, n: n, error: integration.last_error.to_s.truncate(120)).delete_suffix(" · "), since: integration.last_ok_at)
      end
    end

    # Hub (Tuya, Zigbee atrás de gateway) fora: os filhos caem juntos.
    class HubDown < Rule
      describe key: "hub_down", label: "Hub fora", severity: "error", icon: "status-offline",
               description: "O hub/gateway está sem sinal e os aparelhos ligados a ele caíram junto."
      texts "pt-BR" => { reason: "O hub está sem sinal: os aparelhos atrás dele caem junto. Confira energia e rede do hub antes de mexer nos outros.",
                         detail: "%{n} aparelho(s) dependem dele: %{names}" },
            en: { label: "Hub down", description: "The hub/gateway is offline and the devices behind it dropped too.",
                  reason: "The hub is offline: the devices behind it drop too. Check the hub's power and network before touching the others.",
                  detail: "%{n} device(s) depend on it: %{names}" },
            es: { label: "Hub caído", description: "El hub/gateway está sin señal y los dispositivos detrás de él cayeron también.",
                  reason: "El hub está sin señal: los dispositivos detrás de él caen también. Revisa energía y red del hub antes de tocar los demás.",
                  detail: "%{n} dispositivo(s) dependen de él: %{names}" }

      def self.applies?(device, ctx)
        ctx.offline?(device) && ctx.children(device).count { |c| ctx.offline?(c) } >= ctx.config.fetch("hub_min_children")
      end

      def self.fixes(_device, _ctx) = %w[reconnect scan replace]

      def self.finding(device, ctx)
        kids = ctx.children(device)
        super(device, ctx, detail: text(:detail, n: kids.size, names: kids.first(5).map(&:name).join(", ")), since: ctx.offline_since(device))
      end
    end

    # Sem sinal (aparelho queimado, sem energia, fora do Wi-Fi ou IP trocado).
    class Offline < Rule
      describe key: "offline", label: "Sem sinal", icon: "status-offline",
               description: "O aparelho não responde há mais tempo que o limite do local."
      texts "pt-BR" => { reason: "Sem energia, fora do Wi-Fi ou queimado.",
                         reason_lan: "Sem energia, fora da rede ou o IP mudou (DHCP): reconecte ou varra a conta para achar o IP novo.",
                         reason_long: "Sem sinal há dias: provavelmente queimado ou desligado de vez. Troque e use \"Substituir aparelho\".",
                         detail: "Último contato %{ago}", never: "Nunca respondeu" },
            en: { label: "Offline", description: "The device hasn't answered for longer than the site's limit.",
                  reason: "No power, off the Wi-Fi or burned out.",
                  reason_lan: "No power, off the network or its IP changed (DHCP): reconnect or scan the account to find the new IP.",
                  reason_long: "Offline for days: probably burned out or unplugged for good. Swap it and use \"Replace device\".",
                  detail: "Last contact %{ago}", never: "Never answered" },
            es: { label: "Sin señal", description: "El dispositivo no responde hace más que el límite del sitio.",
                  reason: "Sin energía, fuera del Wi-Fi o quemado.",
                  reason_lan: "Sin energía, fuera de la red o cambió la IP (DHCP): reconecta o escanea la cuenta para hallar la IP nueva.",
                  reason_long: "Sin señal hace días: probablemente quemado o desenchufado. Cámbialo y usa \"Reemplazar dispositivo\".",
                  detail: "Último contacto %{ago}", never: "Nunca respondió" }

      def self.applies?(device, ctx)
        ctx.offline?(device) && !ctx.covered?(device) && !HubDown.applies?(device, ctx) &&
          ctx.offline_since(device) <= ctx.now - ctx.settings["offline_hours"].to_i.hours
      end

      def self.fixes(_device, _ctx) = %w[apply_ip reconnect scan pair edit replace delete_device]

      def self.finding(device, ctx)
        since = ctx.offline_since(device)
        long = since <= ctx.now - ctx.settings["offline_error_days"].to_i.days
        reason = if long then text(:reason_long)
        elsif device.address.to_h["host"].present? then text(:reason_lan)
        else text(:reason)
        end
        detail = device.last_seen_at ? text(:detail, ago: ago(since, ctx.now)) : text(:never)
        detail = [ detail, device.last_error.presence&.truncate(120) ].compact.join(" · ")
        super(device, ctx, severity: long ? "error" : "warn", reason: reason, detail: detail, since: since)
      end
    end

    # A conta conhece outro IP para o aparelho local (o roteador trocou por DHCP).
    class IpChanged < Rule
      describe key: "ip_changed", label: "IP mudou", icon: "refresh",
               description: "A varredura da conta mostra um IP diferente do cadastrado."
      texts "pt-BR" => { reason: "O roteador deu outro IP ao aparelho (DHCP). Use o IP novo; para não voltar a acontecer, reserve o IP no roteador.",
                         detail: "Cadastrado %{old} · na conta %{new}" },
            en: { label: "IP changed", description: "The account scan shows an IP different from the registered one.",
                  reason: "The router gave the device another IP (DHCP). Use the new IP; to keep it from happening again, reserve the IP on the router.",
                  detail: "Registered %{old} · in the account %{new}" },
            es: { label: "La IP cambió", description: "El escaneo de la cuenta muestra una IP distinta de la registrada.",
                  reason: "El router dio otra IP al dispositivo (DHCP). Usa la IP nueva; para que no vuelva a pasar, reserva la IP en el router.",
                  detail: "Registrada %{old} · en la cuenta %{new}" }

      def self.applies?(device, _ctx) = device.removed_at.nil? && Fixes::ApplyIp.new_host(device).present?
      def self.fixes(_device, _ctx) = %w[apply_ip reconnect scan]

      def self.finding(device, ctx)
        super(device, ctx, detail: text(:detail, old: device.address.to_h["host"], new: Fixes::ApplyIp.new_host(device)))
      end
    end

    class RemovedFromAccount < Rule
      describe key: "removed", label: "Removido da conta", icon: "trash",
               description: "O aparelho sumiu da conta da nuvem, mas o cadastro continua aqui."
      texts "pt-BR" => { reason: "Saiu da conta da nuvem (removido no app do fabricante ou trocado). Se foi trocado, passe os pontos com \"Substituir aparelho\"; se não existe mais, apague o cadastro.",
                         detail: "Removido %{ago}" },
            en: { label: "Removed from the account", description: "The device left the cloud account, but its record is still here.",
                  reason: "It left the cloud account (removed in the maker's app or swapped). If it was swapped, move the points with \"Replace device\"; if it's gone, delete the record.",
                  detail: "Removed %{ago}" },
            es: { label: "Quitado de la cuenta", description: "El dispositivo salió de la cuenta en la nube, pero el registro sigue aquí.",
                  reason: "Salió de la cuenta en la nube (quitado en la app del fabricante o cambiado). Si se cambió, pasa los puntos con \"Reemplazar dispositivo\"; si ya no existe, borra el registro.",
                  detail: "Quitado %{ago}" }

      def self.applies?(device, _ctx) = device.removed_at.present?
      def self.fixes(_device, _ctx) = %w[replace scan delete_device]
      def self.finding(device, ctx) = super(device, ctx, detail: text(:detail, ago: ago(device.removed_at, ctx.now)), since: device.removed_at)
    end

    class NoPoints < Rule
      describe key: "no_points", label: "Sem pontos", icon: "chip",
               description: "Aparelho cadastrado sem nenhum ponto: não aparece em painel nem automação."
      texts "pt-BR" => { reason: "O cadastro ficou sem pontos (adoção incompleta, mapa de dados que não conhece o modelo ou cadastro à mão). Varra a conta de novo ou apague o cadastro." },
            en: { label: "No points", description: "Device registered without any point: it shows up in no dashboard or automation.",
                  reason: "The record has no points (incomplete adoption, a data map that doesn't know the model, or a manual record). Scan the account again or delete the record." },
            es: { label: "Sin puntos", description: "Dispositivo registrado sin ningún punto: no aparece en paneles ni automatizaciones.",
                  reason: "El registro quedó sin puntos (adopción incompleta, mapa de datos que no conoce el modelo o registro manual). Escanea la cuenta de nuevo o borra el registro." }

      def self.applies?(device, ctx)
        device.removed_at.nil? && ctx.points_of(device).empty? && device.created_at <= ctx.now - ctx.config.fetch("no_points_grace_hours").hours
      end

      def self.fixes(_device, _ctx) = %w[scan edit delete_device]
    end

    # Dois cadastros do mesmo aparelho (mesmo external_id ou mesmo endereço).
    # O achado fica no mais novo: em geral é ele que sobra.
    class Duplicate < Rule
      describe key: "duplicate", label: "Duplicado", icon: "duplicate",
               description: "Dois cadastros apontam para o mesmo aparelho (mesmo identificador ou mesmo endereço)."
      texts "pt-BR" => { reason: "Dois cadastros do mesmo aparelho brigam pela conexão e confundem painel e automação. Passe os pontos para o que fica (\"Substituir aparelho\") ou apague o que sobra.",
                         detail: "Igual a: %{names}" },
            en: { label: "Duplicate", description: "Two records point to the same device (same identifier or same address).",
                  reason: "Two records of the same device fight over the connection and confuse dashboards and automations. Move the points to the one that stays (\"Replace device\") or delete the extra one.",
                  detail: "Same as: %{names}" },
            es: { label: "Duplicado", description: "Dos registros apuntan al mismo dispositivo (mismo identificador o misma dirección).",
                  reason: "Dos registros del mismo dispositivo pelean por la conexión y confunden paneles y automatizaciones. Pasa los puntos al que queda (\"Reemplazar dispositivo\") o borra el sobrante.",
                  detail: "Igual a: %{names}" }

      def self.applies?(device, ctx)
        others = ctx.duplicates_of(device)
        others.any? && others.all? { |o| ([ o.created_at, o.id ] <=> [ device.created_at, device.id ]).negative? }
      end

      def self.fixes(_device, _ctx) = %w[replace delete_device]
      def self.finding(device, ctx) = super(device, ctx, detail: text(:detail, names: ctx.duplicates_of(device).map(&:name).join(", ")))
    end

    # Câmera (driver go2rtc) sem fonte de vídeo: falta IP, caminho RTSP ou a senha.
    class CameraNoStream < Rule
      describe key: "camera_no_stream", label: "Câmera sem vídeo", icon: "video-camera",
               description: "Câmera sem endereço RTSP/ONVIF utilizável: o vídeo não sobe."
      texts "pt-BR" => { reason: "Falta o IP, o caminho RTSP ou a senha da câmera: o go2rtc não tem de onde puxar o vídeo. Confira o cadastro ou reconfigure a câmera (RTSP ou ONVIF).",
                         detail: "%{n} canal(is) sem fonte" },
            en: { label: "Camera without video", description: "Camera with no usable RTSP/ONVIF address: the video doesn't come up.",
                  reason: "The camera's IP, RTSP path or password is missing: go2rtc has nowhere to pull the video from. Check the record or reconfigure the camera (RTSP or ONVIF).",
                  detail: "%{n} channel(s) without a source" },
            es: { label: "Cámara sin video", description: "Cámara sin dirección RTSP/ONVIF utilizable: el video no sube.",
                  reason: "Falta la IP, la ruta RTSP o la contraseña de la cámara: go2rtc no tiene de dónde tomar el video. Revisa el registro o reconfigura la cámara (RTSP u ONVIF).",
                  detail: "%{n} canal(es) sin fuente" }

      def self.streams(device, ctx) = ctx.points_of(device).select { |p| p.capability == "stream" && !p.address.to_h["on_demand"] }

      def self.missing(device, ctx) = streams(device, ctx).select { |p| Drivers::Go2rtc.source(p).nil? }

      def self.applies?(device, ctx)
        device.removed_at.nil? && device.driver == "go2rtc" && (streams(device, ctx).empty? || missing(device, ctx).any?)
      end

      def self.fixes(_device, _ctx) = %w[edit reconfigure replace]
      def self.finding(device, ctx) = super(device, ctx, detail: text(:detail, n: [ missing(device, ctx).size, 1 ].max))
    end

    class NoArea < Rule
      describe key: "no_area", label: "Sem área", severity: "info", icon: "home",
               description: "Aparelho sem área: fica de fora das visões por cômodo e da voz por cômodo."
      texts "pt-BR" => { reason: "Sem área, o aparelho não aparece nas visões por cômodo nem responde a \"apague a luz da sala\"." },
            en: { label: "No area", description: "Device without an area: left out of the per-room views and per-room voice.",
                  reason: "Without an area, the device doesn't show in the per-room views nor answer \"turn off the living room light\"." },
            es: { label: "Sin área", description: "Dispositivo sin área: queda fuera de las vistas por ambiente y de la voz por ambiente.",
                  reason: "Sin área, el dispositivo no aparece en las vistas por ambiente ni responde a \"apaga la luz de la sala\"." }

      def self.applies?(device, ctx)
        device.removed_at.nil? && device.area_id.nil? && ctx.points_of(device).any? && ctx.points_of(device).none?(&:area_id)
      end

      def self.fixes(_device, _ctx) = %w[set_area]
    end

    # Bateria baixa: ponto de bateria (device_class battery ou o `battery_point_id`).
    class BatteryLow < Rule
      describe key: "battery_low", label: "Bateria baixa", subject: :point, icon: "battery", notify: true,
               description: "A bateria do sensor está abaixo do limite do local."
      texts "pt-BR" => { reason: "Troque a bateria logo: com pouca carga o sensor começa a falhar e some de vez.", detail: "Bateria em %{v}% (limite %{min}%)" },
            en: { label: "Low battery", description: "The sensor's battery is below the site's limit.",
                  reason: "Replace the battery soon: low on charge, the sensor starts failing and then drops for good.", detail: "Battery at %{v}% (limit %{min}%)" },
            es: { label: "Batería baja", description: "La batería del sensor está debajo del límite del sitio.",
                  reason: "Cambia la batería pronto: con poca carga el sensor empieza a fallar y luego se cae del todo.", detail: "Batería en %{v}% (límite %{min}%)" }

      def self.battery?(point) = point.device_class == "battery" || point.device&.battery_point_id == point.id
      def self.level(point) = point.value.is_a?(Numeric) ? point.value.to_f : Float(point.value.to_s, exception: false)

      def self.applies?(point, ctx)
        battery?(point) && point.quality != "unavailable" && (v = level(point)) && v <= ctx.settings["battery_low_pct"].to_f
      end

      def self.finding(point, ctx)
        v = level(point)
        super(point, ctx, severity: v <= ctx.settings["battery_critical_pct"].to_f ? "error" : "warn",
                          detail: text(:detail, v: num(v), min: ctx.settings["battery_low_pct"]), since: point.changed_at)
      end
    end

    # Medida em 0 há horas (umidade do solo 0% = sensor fora da terra).
    class ZeroReading < Rule
      describe key: "zero_reading", label: "Leitura zerada", subject: :point, icon: "beaker",
               description: "A medida está em zero há horas, o que não é plausível para a classe do sensor."
      texts "pt-BR" => { reason: "Zero há horas não é plausível: sensor desconectado, fora do lugar ou com defeito.",
                         "reason.moisture" => "Umidade do solo em 0% há horas: o sensor provavelmente está fora da terra ou desconectado.",
                         "reason.humidity" => "Umidade em 0% há horas: o sensor está com defeito ou desconectado.",
                         detail: "Em %{v}%{unit} %{ago}" },
            en: { label: "Zeroed reading", description: "The measurement has been at zero for hours, which isn't plausible for the sensor's class.",
                  reason: "Zero for hours isn't plausible: sensor disconnected, out of place or faulty.",
                  "reason.moisture" => "Soil moisture at 0% for hours: the sensor is probably out of the soil or disconnected.",
                  "reason.humidity" => "Humidity at 0% for hours: the sensor is faulty or disconnected.",
                  detail: "At %{v}%{unit} since %{ago}" },
            es: { label: "Lectura en cero", description: "La medida está en cero hace horas, lo que no es plausible para la clase del sensor.",
                  reason: "Cero por horas no es plausible: sensor desconectado, fuera de lugar o con falla.",
                  "reason.moisture" => "Humedad del suelo en 0% hace horas: el sensor probablemente está fuera de la tierra o desconectado.",
                  "reason.humidity" => "Humedad en 0% hace horas: el sensor tiene falla o está desconectado.",
                  detail: "En %{v}%{unit} %{ago}" }

      def self.applies?(point, ctx)
        hours = ctx.sensor(point)["zero_hours"] or return false
        point.capability == "measure" && point.quality == "good" && point.value.is_a?(Numeric) && point.value.to_f <= 0 &&
          point.changed_at.present? && point.changed_at <= ctx.now - hours.to_f.hours
      end

      def self.fixes(_point, _ctx) = %w[reconnect]

      def self.finding(point, ctx)
        super(point, ctx, reason: text("reason.#{point.device_class}", default: text(:reason)), since: point.changed_at,
                          detail: text(:detail, v: num(point.value), unit: point.unit.to_s, ago: ago(point.changed_at, ctx.now)))
      end
    end

    # Valor parado há muito com o aparelho respondendo (sensor travado).
    class ValueStuck < Rule
      describe key: "value_stuck", label: "Valor parado", subject: :point, icon: "clock",
               description: "A medida não muda há muito tempo, mesmo com o aparelho respondendo."
      texts "pt-BR" => { reason: "O aparelho responde, mas o valor não muda: sensor travado, fora do lugar ou com o firmware preso. Reconectar força uma leitura.",
                         detail: "%{v}%{unit} sem mudar %{ago}" },
            en: { label: "Stuck value", description: "The measurement hasn't changed in a long time, even with the device answering.",
                  reason: "The device answers, but the value doesn't change: sensor stuck, out of place or with frozen firmware. Reconnecting forces a reading.",
                  detail: "%{v}%{unit} unchanged since %{ago}" },
            es: { label: "Valor detenido", description: "La medida no cambia hace mucho, aunque el dispositivo responde.",
                  reason: "El dispositivo responde, pero el valor no cambia: sensor trabado, fuera de lugar o con el firmware colgado. Reconectar fuerza una lectura.",
                  detail: "%{v}%{unit} sin cambiar %{ago}" }

      def self.applies?(point, ctx)
        hours = ctx.sensor(point)["stuck_hours"] or return false
        return false unless point.capability == "measure" && point.quality == "good" && point.changed_at && point.device.status == "online"
        return false if ZeroReading.applies?(point, ctx) # zerado tem motivo próprio

        point.changed_at <= ctx.now - hours.to_f.hours
      end

      def self.fixes(_point, _ctx) = %w[reconnect]

      def self.finding(point, ctx)
        super(point, ctx, since: point.changed_at, detail: text(:detail, v: point.value.is_a?(Numeric) ? num(point.value) : point.value.to_s,
                                                                        unit: point.unit.to_s, ago: ago(point.changed_at, ctx.now)))
      end
    end

    # Pulo absurdo entre duas leituras seguidas (interferência, sensor solto, bateria fraca).
    class ValueJump < Rule
      describe key: "value_jump", label: "Pulo absurdo", subject: :point, icon: "trending-up",
               description: "Duas leituras seguidas com diferença maior que o plausível para a classe do sensor."
      texts "pt-BR" => { reason: "Mudança grande demais em pouco tempo: mau contato, sensor solto, bateria fraca ou interferência. Automação que usa este valor pode disparar à toa.",
                         detail: "De %{from} para %{to}%{unit} em %{min} min" },
            en: { label: "Absurd jump", description: "Two consecutive readings with a gap bigger than plausible for the sensor's class.",
                  reason: "Too big a change in too little time: bad contact, loose sensor, weak battery or interference. Automations using this value may fire for nothing.",
                  detail: "From %{from} to %{to}%{unit} in %{min} min" },
            es: { label: "Salto absurdo", description: "Dos lecturas seguidas con una diferencia mayor que la plausible para la clase del sensor.",
                  reason: "Cambio demasiado grande en poco tiempo: mal contacto, sensor suelto, batería débil o interferencia. Las automatizaciones que usan este valor pueden dispararse sin motivo.",
                  detail: "De %{from} a %{to}%{unit} en %{min} min" }

      def self.applies?(point, ctx) = ctx.jumps.key?(point.id)
      def self.fixes(_point, _ctx) = %w[reconnect]

      def self.finding(point, ctx)
        j = ctx.jumps.fetch(point.id)
        super(point, ctx, since: j[:at], detail: text(:detail, from: num(j[:from]), to: num(j[:to]), unit: point.unit.to_s, min: j[:minutes]))
      end
    end
  end
end
