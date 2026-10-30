# Integrações de conta (F8c), abertas para extensão: cada tipo é um plugin
# (`Integrations::Plugin`, um arquivo em app/services/integrations/)
# registrado em `PLUGINS`; o catálogo, o assistente, o login, a varredura e
# as telas saem do plugin, sem `case` por tipo fora dele. Aqui fica o que é
# comum: varredura (`sync!`, manual ou periódica) e adoção (`adopt!`).
#
# Inventário = lista de entradas no mesmo formato para todos: {id, kind
# (driver do aparelho), name, manufacturer, model, category, room, online,
# sub, secret (local_key/token), address, poll_s, points: [atributos]}.
# Aparelho já cadastrado (driver + external_id; câmera também pelo IP) nunca
# duplica: a varredura só o liga à integração e atualiza a chave/IP. O que
# sumiu da conta fica com `removed_at` (nada é apagado). Aparelho novo na
# conta vira notificação "Novo dispositivo encontrado" e conta no card.
module Integrations
  class Error < StandardError; end

  # Ordem = ordem do catálogo. Integração nova: classe + uma linha aqui.
  PLUGINS = %w[TuyaPlugin XiaomiPlugin AlexaPlugin HikvisionPlugin MqttPlugin Zigbee2mqttPlugin HaImportPlugin].freeze

  module_function

  def plugins = PLUGINS.map { |name| const_get(name) }
  def plugin(key) = plugins.find { |p| p.key == key.to_s }
  def for_driver(driver) = plugins.find { |p| p.driver == driver.to_s }
  def drivers = plugins.filter_map(&:driver).uniq

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
    integration.update!(inventory: list.to_json)
    integration.ok!
    known = matched_ids(integration)
    fresh = list.reject { |e| known.include?(e["id"]) || before.include?(e["id"]) }
    notify_new(integration, fresh) if fresh.any? && !first
    counts.merge(found: list.size, fresh: fresh.size)
  rescue StandardError => e
    integration.error!(e.message) if integration.persisted?
    raise
  end

  def reconcile(integration, list)
    keys = 0
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
    end
    ids = list.map { |e| e["id"] }
    removed = Device.where(integration_id: integration.id, removed_at: nil).where.not(external_id: ids).update_all(removed_at: Time.current)
    { removed: removed, keys: keys }
  end

  # Entrada com "match" => "host": aparelho cadastrado antes (sem external_id) casa pelo IP.
  def existing(site, e)
    scope = site.devices.where(driver: e["kind"])
    scope.find_by(external_id: e["id"]) || (scope.find_by("address->>'host' = ?", e["id"]) if e["match"] == "host")
  end

  # ids do inventário que já são aparelhos do local (uma consulta só).
  def matched_ids(integration)
    list = integration.found
    rows = integration.site.devices.where(driver: list.map { |e| e["kind"] }.uniq).pluck(:driver, :external_id, Arel.sql("address->>'host'"))
    by_ext = rows.to_set { |d, ext, _| [ d, ext ] }
    by_host = rows.to_set { |d, _, h| [ d, h ] }
    list.filter_map { |e| e["id"] if by_ext.include?([ e["kind"], e["id"] ]) || (e["match"] == "host" && by_host.include?([ e["kind"], e["id"] ])) }.to_set
  end

  # Encontrados e ainda não adicionados (o "novo" do card).
  def pending(integration)
    known = matched_ids(integration)
    integration.found.reject { |e| known.include?(e["id"]) || e["sub"] }
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
    picks.sum do |id, area_ref|
      e = by_id[id]
      next 0 if e.nil? || e["sub"] || known.include?(id)

      ActiveRecord::Base.transaction { create_device(integration, site, e, area_for(site, area_ref)) }
      1
    end
  end

  def create_device(integration, site, e, area)
    secret = for_driver(integration.driver).device_secret(integration, e)
    device = site.devices.create!(driver: e["kind"], name: e["name"], external_id: e["id"], integration: integration, area: area,
                                  manufacturer: e["manufacturer"], model: e["model"], address: e["address"] || {}, credential: secret,
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
    base = [ device.name, name ].map { |s| s.to_s.parameterize(separator: "_").presence || "ponto" }.join(".")
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
