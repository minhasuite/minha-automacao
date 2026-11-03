# Integrações de conta (F8c), abertas para extensão: cada tipo é um plugin
# (`Integrations::Plugin`, um arquivo em app/services/integrations/)
# registrado em `PLUGINS`; o catálogo, o assistente, o login, a varredura e
# as telas saem do plugin, sem `case` por tipo fora dele. Aqui fica o que é
# comum: varredura (`sync!`, manual ou periódica) e adoção (`adopt!`).
#
# Inventário = lista de entradas no mesmo formato para todos: {id, kind
# (driver do aparelho), match_drivers (outros drivers que são o mesmo
# aparelho, ex.: Tuya nuvem e local), name, manufacturer, model, category,
# room, online, sub, secret (local_key/token), address (via = id do hub),
# poll_s, points: [atributos]}. Depois da varredura e da adoção o plugin
# pode gravar o estado (`refresh`).
# Aparelho já cadastrado (driver + external_id; câmera também pelo IP) nunca
# duplica: a varredura só o liga à integração e atualiza a chave/IP. O que
# sumiu da conta fica com `removed_at` (nada é apagado). Aparelho novo na
# conta vira notificação "Novo dispositivo encontrado" e conta no card.
module Integrations
  class Error < StandardError; end

  # Erro de credencial (senha errada, sessão vencida, sem login): marca a
  # exceção (`Integrations.auth(Error.new(...))`) e a tela de encontrados
  # oferece "Reconfigurar"; rede e servidor fora oferecem "Tentar de novo".
  module AuthError; end

  # Ordem = ordem do catálogo. Integração nova: classe + uma linha aqui.
  PLUGINS = %w[TuyaPlugin XiaomiPlugin AlexaPlugin CameraPlugin HikvisionPlugin MqttPlugin Zigbee2mqttPlugin
               EsphomePlugin ShellyPlugin TasmotaPlugin MatterPlugin CastPlugin WebosPlugin TizenPlugin AdbPlugin BroadlinkPlugin SpotifyPlugin
               FrigatePlugin ReolinkPlugin UnifiProtectPlugin HuePlugin WledPlugin YeelightPlugin SwitchbotPlugin
               DaikinPlugin MideaPlugin LgThinqPlugin SunspecPlugin GrowattPlugin DirigeraPlugin SonosPlugin DlnaPlugin GoveePlugin ZwaveJsPlugin BleProxyPlugin BluetoothPlugin ThreadPlugin GoogleHomePlugin HomekitPlugin
               WizPlugin TplinkPlugin AdguardPlugin NutPlugin FullyKioskPlugin HomewizardPlugin SynologyDsmPlugin FritzboxPlugin DenonavrPlugin HeosPlugin BraviatvPlugin
               ForecastSolarPlugin Co2signalPlugin MoonPlugin SeasonPlugin HolidayPlugin
               SmartthingsPlugin NetatmoPlugin HomeConnectPlugin NestPlugin EcowittPlugin OverkizPlugin RingPlugin
               UnifiPlugin SpeedtestPlugin IppPlugin InfluxdbPlugin ModbusPlugin OnedrivePlugin UpnpPlugin FritzPlugin MusicAssistantPlugin PlexPlugin
               BrotherPlugin SmlightPlugin LutronCasetaPlugin
               AndroidtvRemotePlugin AppleTvPlugin
               CalendarPlugin WeatherPlugin MobileAppPlugin NetworkTrackerPlugin TelegramPlugin WhatsappPlugin HttpMessengerPlugin SystemPlugin HaImportPlugin HomeAssistantPlugin].freeze

  module_function

  def auth(error) = error.extend(AuthError)

  # A cada minuto (RunSchedulesJob): plugin que precisa do relógio (agenda).
  def tick(now = Time.current) = plugins.each { |p| p.tick(now) }

  # `state` do OAuth (F9), assinado, 15 min: id da integração ou um texto de
  # outro dono do retorno (ex.: "backup_drive:<usuário>", o Drive do backup).
  def oauth_state(target)
    payload = target.is_a?(Integration) ? target.id : target
    Rails.application.message_verifier(:integration_oauth).generate(payload, expires_in: 15.minutes)
  end
  def from_oauth_state(state) = Rails.application.message_verifier(:integration_oauth).verified(state.to_s)

  def plugins = PLUGINS.map { |name| const_get(name) }
  def plugin(key) = plugins.find { |p| p.key == key.to_s }
  def for_driver(driver) = plugins.find { |p| p.driver == driver.to_s }
  def drivers = plugins.filter_map(&:driver).uniq
  # catalogo: plugin que também é o driver dos seus aparelhos (SchemaPlugin).
  def device_kinds = plugins.flat_map(&:device_kinds)
  def device_driver(kind) = plugins.lazy.filter_map { |p| p.device_driver(kind.to_s) }.first

  # Quadro de um ponto de câmera pelo plugin do aparelho (integ); nil = não tem.
  def snapshot(point) = for_driver(point.device.driver)&.snapshot(point)

  # Marca "Sincronizando" e põe a varredura na fila.
  def start_sync!(integration)
    integration.update_columns(status: "syncing")
    SyncIntegrationJob.perform_later(integration.id)
    true
  end

  # Varre a conta. → {found:, fresh:, removed:, keys:}. Erro fica na integração e sobe.
  def sync!(integration)
    plugin = for_driver(integration.driver) or raise Error, "Integração sem plugin: #{integration.driver}"
    return plugin.sync!(integration) if plugin.custom_sync?

    integration.update_columns(status: "syncing")
    first = integration.inventory.blank?
    before = integration.found.map { |e| e["id"] }
    list = plugin.inventory(integration).select { |e| e["id"].present? }
    counts = reconcile(integration, list)
    DebugLog.log(integration, "varredura: #{list.size} aparelho(s): #{list.map { |e| e['id'] }.first(50).join(", ")}")
    integration.update!(inventory: list.to_json)
    integration.ok!
    plugin.refresh(integration)
    known = matched_ids(integration)
    fresh = list.reject { |e| known.include?(e["id"]) || before.include?(e["id"]) }
    notify_new(integration, fresh) if fresh.any? && !first
    counts.merge(found: list.size, fresh: fresh.size)
  rescue StandardError => e
    integration.error!(e) if integration.persisted?
    DebugLog.log(integration, "varredura falhou: #{e.class}: #{e.message}")
    raise
  end

  def reconcile(integration, list)
    keys = 0
    added = 0
    list.each do |e|
      device = existing(integration.site, e) or next
      device.assign_attributes(integration_id: integration.id, removed_at: nil, external_id: device.external_id.presence || e["id"])
      if e["secret"].present? && device.credential != e["secret"]
        device.credential = e["secret"]
        keys += 1
      end
      host = e.dig("address", "host")
      device.address = device.address.merge("host" => host) if host.present? && device.address["host"] != host
      device.save! if device.changed?
      added += add_points(device, e)
    end
    ids = list.map { |e| e["id"] }
    removed = Device.where(integration_id: integration.id, removed_at: nil).where.not(external_id: ids).update_all(removed_at: Time.current)
    { removed: removed, keys: keys, points: added }
  end

  # Lote 8: ponto que o mapa de dados passou a trazer (cor, evento do robô)
  # entra no aparelho já cadastrado. Casa pelo endereço (dp ou siid/piid/eiid);
  # o que já existe não muda.
  IDENTITY = %w[dps siid piid eiid].freeze
  def add_points(device, e)
    have = device.points.map { |p| p.address.slice(*IDENTITY).transform_values(&:to_s) }
    Array(e["points"]).count do |p|
      id = p["address"].to_h.slice(*IDENTITY).transform_values(&:to_s)
      next false if id.empty? || have.include?(id)

      device.points.create!(p.merge("site" => device.site, "key" => unique_key(device.site, device, p["name"])))
      have << id
    end
  end

  # Entrada com "match" => "host": aparelho cadastrado antes (sem external_id) casa pelo IP.
  def existing(site, e)
    scope = site.devices.where(driver: drivers_of(e))
    scope.find_by(external_id: e["id"]) || (scope.find_by("address->>'host' = ?", e["id"]) if e["match"] == "host")
  end

  # ids do inventário que já são aparelhos do local (uma consulta só).
  def matched_ids(integration)
    list = integration.found
    rows = integration.site.devices.where(driver: list.flat_map { |e| drivers_of(e) }.uniq).pluck(:driver, :external_id, Arel.sql("address->>'host'"))
    by_ext = rows.to_set { |d, ext, _| [ d, ext ] }
    by_host = rows.to_set { |d, _, h| [ d, h ] }
    list.filter_map do |e|
      e["id"] if drivers_of(e).any? { |d| by_ext.include?([ d, e["id"] ]) || (e["match"] == "host" && by_host.include?([ d, e["id"] ])) }
    end.to_set
  end

  def drivers_of(e) = Array(e["match_drivers"].presence || e["kind"])

  # Encontrados e ainda não adicionados (o "novo" do card).
  def pending(integration)
    known = matched_ids(integration)
    integration.found.reject { |e| known.include?(e["id"]) }
  end

  # Área sugerida pelo cômodo da nuvem: área de mesmo nome, ou "new:<cômodo>".
  def suggest_area(site, room, areas = site.areas.to_a)
    return "" if room.blank?

    areas.find { |a| a.name.casecmp?(room.squish) }&.id || "new:#{room.squish}"
  end

  # picks: {id do inventário → área ("" | uuid | "new:Nome")}. → quantos entraram.
  def adopt!(integration, picks)
    site = integration.site
    known = matched_ids(integration)
    by_id = integration.found.index_by { |e| e["id"] }
    added = picks.sum do |id, area_ref|
      e = by_id[id]
      next 0 if e.nil? || known.include?(id)

      ActiveRecord::Base.transaction { create_device(integration, site, e, area_for(site, area_ref)) }
      1
    end
    for_driver(integration.driver).refresh(integration) if added.positive?
    added
  end

  def create_device(integration, site, e, area)
    secret = for_driver(integration.driver).device_secret(integration, e)
    device = site.devices.create!(driver: e["kind"], name: e["name"], external_id: e["id"], integration: integration, area: area,
                                  manufacturer: e["manufacturer"], model: e["model"], firmware: e["firmware"], address: e["address"] || {}, credential: secret,
                                  poll_s: e["poll_s"] || 1800, discovered_at: Time.current)
    Array(e["points"]).each do |p|
      device.points.create!(p.merge("site" => site, "key" => unique_key(site, device, p["name"])))
    end
    device
  end

  def area_for(site, ref)
    ref = ref.to_s
    return site.areas.find_or_create_by!(name: ref.delete_prefix("new:").squish) if ref.start_with?("new:") && ref.length > 4

    site.areas.find_by(id: ref) if ref.match?(/\A\h{8}-/)
  end

  def unique_key(site, device, name)
    base = [ device.name, name ].map { |s| s.to_s.parameterize(separator: "_").tr("-", "_").presence || "ponto" }.join(".")
    key = base
    n = 1
    key = "#{base}_#{n += 1}" while site.points.exists?(key: key)
    key
  end

  def notify_new(integration, fresh)
    names = fresh.first(3).map { |e| e["name"] }.join(", ") + (fresh.size > 3 ? " e mais #{fresh.size - 3}" : "")
    Notifier.notify!(kind: "integracao", title: fresh.one? ? "Novo dispositivo encontrado" : "#{fresh.size} novos dispositivos encontrados",
                     body: "#{integration.name}: #{names}. Abra a integração para adicionar.",
                     data: { integration_id: integration.id, site_id: integration.site_id },
                     dedup_key: "integracao:#{integration.id}:#{Digest::SHA1.hexdigest(fresh.map { |e| e['id'] }.sort.join(','))}")
  end
end
