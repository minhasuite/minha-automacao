module Integrations
  # Migração do Home Assistant em sombra (F10): traz a casa do HA para um
  # local daqui sem comandar nada. Entrada = arquivos do HA (só leitura):
  # `area_registry`, `device_registry`, `entity_registry` (os JSON de
  # `.storage`), `states` (GET /api/states), `automations`, `scripts` e
  # `scenes` (YAML). Passos, todos idempotentes pelo de-para (ExternalRef,
  # fonte "home_assistant"):
  #   1. áreas do HA → áreas daqui (pelo nome);
  #   2. aparelhos que as integrações daqui já encontraram e ainda não foram
  #      adicionados entram na área do HA (`Integrations.adopt!`), e os já
  #      cadastrados vão para a área do HA;
  #   3. entidade do HA → ponto daqui (aparelho pelo identificador do
  #      registro, ponto pelo código/dp/propriedade do `unique_id`);
  #   4. helpers (input_*, timer, counter, grupos) → helpers daqui;
  #   5. cenas → cenas daqui; scripts e automações → blueprints (HaImport) e
  #      daí automações com as entradas resolvidas pelo de-para.
  # Tudo nasce em sombra; automação fica ligada só se estiver ligada no HA.
  class HomeAssistantImport
    SOURCE = "home_assistant".freeze
    # Helper do HA → [tipo daqui, formulário a partir dos atributos do estado].
    HELPERS = {
      "input_boolean" => [ "toggle", ->(_a) { {} } ],
      "input_number" => [ "number", ->(a) { { "min" => a["min"], "max" => a["max"], "step" => a["step"], "unit" => a["unit_of_measurement"] } } ],
      "input_select" => [ "select", ->(a) { { "options_text" => Array(a["options"]).join("\n") } } ],
      "input_text" => [ "text", ->(a) { { "min" => a["min"], "max" => a["max"], "password" => a["mode"] == "password" } } ],
      "input_datetime" => [ "datetime", ->(a) { { "mode" => if a["has_date"] && a["has_time"] then "datetime" else (a["has_date"] ? "date" : "time") end } } ],
      "input_button" => [ "button", ->(_a) { {} } ],
      "timer" => [ "timer", ->(a) { { "duration" => a["duration"].to_s.split(":").map(&:to_i).then { |h, m, s| "#{(h.to_i * 3600) + (m.to_i * 60) + s.to_i}s" } } } ],
      "counter" => [ "counter", ->(a) { { "initial" => a["initial"], "step" => a["step"], "min" => a["minimum"], "max" => a["maximum"] } } ]
    }.freeze
    # Domínio do HA → capacidade daqui, quando o aparelho tem um ponto só dela.
    DOMAIN_CAPS = { "vacuum" => "vacuum", "media_player" => "speaker", "camera" => "stream" }.freeze

    Result = Struct.new(:areas, :devices_added, :devices_moved, :entities, :unmapped, :helpers, :helpers_skipped, :scenes, :items, keyword_init: true)

    def self.call(site, files) = new(site, files).call

    def initialize(site, files)
      @site = site
      @files = files.transform_keys(&:to_s)
      @r = Result.new(areas: 0, devices_added: 0, devices_moved: 0, entities: 0, unmapped: [], helpers: 0, helpers_skipped: [], scenes: [], items: [])
    end

    def call
      areas!
      devices!
      entities!
      helpers!
      scenes!
      run_items!("script", "scripts")
      run_items!("automation", "automations")
      @r
    end

    private

    def json(name) = (raw = @files[name]).is_a?(String) ? JSON.parse(raw) : raw
    def registry(name, key) = Array(json(name)&.dig("data", key))
    def states = @states ||= Array(json("states")).index_by { |s| s["entity_id"] }
    def link!(ext, kind, target, name = nil, note: nil) = ExternalRef.link!(@site, SOURCE, ext, kind: kind, target: target, name: name, note: note)

    # ---- 1. áreas ---------------------------------------------------------------

    def areas!
      @areas = registry("area_registry", "areas").to_h do |a|
        area = @site.areas.find_by("lower(name) = ?", a["name"].to_s.downcase) || (@r.areas += 1) && @site.areas.create!(name: a["name"])
        link!("area:#{a['id']}", "area", area, a["name"])
        [ a["id"], area ]
      end
    end

    # ---- 2. aparelhos -------------------------------------------------------------

    def devices!
      @ha_devices = registry("device_registry", "devices")
      @site.integrations.each do |integration|
        next if integration.plugin.nil? || integration.plugin.custom_sync?

        picks = Integrations.pending(integration).to_h do |e|
          area = ha_device_for(e["id"])&.then { |d| @areas[d["area_id"]] }
          [ e["id"], area&.id || Integrations.suggest_area(@site, e["room"]) ]
        end
        @r.devices_added += Integrations.adopt!(integration, picks) if picks.any?
      end
      # Um aparelho daqui pode ser vários no HA (ex.: a mesma tomada na
      # integração de nuvem e na local): todos apontam para ele.
      by_ext = @site.devices.where.not(external_id: [ nil, "" ]).index_by(&:external_id)
      @devices = @ha_devices.filter_map { |ha| (d = ha_ids(ha).filter_map { |id| by_ext[id] }.first) && [ ha["id"], d ] }.to_h
      by_id = @ha_devices.index_by { |d| d["id"] }
      @devices.each { |ha_id, device| link!("device:#{ha_id}", "device", device, by_id[ha_id]["name_by_user"] || by_id[ha_id]["name"]) }
      @devices.group_by { |_, d| d }.each do |device, pairs|
        area = pairs.filter_map { |ha_id, _| @areas[by_id[ha_id]["area_id"]] }.first
        next unless area && device.area_id != area.id

        device.update!(area: area)
        @r.devices_moved += 1
      end
    end

    # Identificador do registro do HA = id daqui ou "<prefixo>_<id>" (local_x, us_x).
    def ha_ids(ha) = Array(ha["identifiers"]).flat_map { |_, v| [ v.to_s, v.to_s.split("_", 2).last ] }.uniq
    def ha_device_for(external_id) = @ha_devices.find { |d| ha_ids(d).include?(external_id.to_s) }

    # ---- 3. entidades -------------------------------------------------------------

    def entities!
      registry("entity_registry", "entities").each do |e|
        next if e["disabled_by"].present?

        point = point_for(e) or next
        link!(e["entity_id"], "entity", point, e["name"] || e["original_name"])
        link!("entity:#{e['id']}", "entity_registry", point) if e["id"].present?
        @r.entities += 1
      end
      wanted = registry("entity_registry", "entities").select { |e| e["disabled_by"].blank? && e["device_id"] && @devices[e["device_id"]] }
      @r.unmapped = wanted.map { |e| e["entity_id"] } - ExternalRef.map_for(@site, SOURCE).keys
    end

    def point_for(e)
      device = @devices[e["device_id"]] or return
      uid = e["unique_id"].to_s
      points = device.points.to_a
      by_code = points.select { |p| p.address["code"].present? && uid.end_with?(p.address["code"]) }.max_by { |p| p.address["code"].size }
      by_code || points.find { |p| p.address["dps"].present? && uid.end_with?("_#{p.address['dps']}") } ||
        (uid =~ /_p_(\d+)_(\d+)\z/ && points.find { |p| p.address["siid"].to_i == ::Regexp.last_match(1).to_i && p.address["piid"].to_i == ::Regexp.last_match(2).to_i }) ||
        (cap = DOMAIN_CAPS[e["entity_id"].to_s.split(".").first]) && points.select { |p| p.capability == cap }.then { |l| l.first if l.one? }
    end

    # ---- 4. helpers ---------------------------------------------------------------

    def helpers!
      states.each_value do |s|
        domain = s["entity_id"].split(".").first
        kind, form = HELPERS[domain]
        if kind then helper!(s, kind, form.call(s["attributes"].to_h))
        elsif s.dig("attributes", "entity_id").is_a?(Array) && %w[switch light fan].include?(domain) then group!(s)
        end
      end
    end

    def helper!(s, kind, form)
      return if ExternalRef.find_by(site_id: @site.id, source: SOURCE, external_id: s["entity_id"])&.target

      point = HelperTypes.build(@site, HelperTypes.plugin(kind))
      name = s.dig("attributes", "friendly_name").presence || s["entity_id"]
      return @r.helpers_skipped << "#{s['entity_id']}: #{point.errors.full_messages.to_sentence}" unless HelperTypes.save(point, form.compact.merge("name" => name))

      link!(s["entity_id"], "helper", point, name)
      @r.helpers += 1
    end

    def group!(s)
      return if ExternalRef.find_by(site_id: @site.id, source: SOURCE, external_id: s["entity_id"])&.target

      points = ExternalRef.map_for(@site, SOURCE, "Point")
      members = s.dig("attributes", "entity_id").filter_map { |e| points[e] }
      return @r.helpers_skipped << "#{s['entity_id']}: membros sem de-para" if members.size < 2

      helper!(s, "group", { "members" => members, "mode" => "any" })
    end

    # ---- 5. cenas, scripts e automações ---------------------------------------------

    def scenes!
      Array(YAML.safe_load(@files["scenes"].to_s, aliases: false)).each do |sc|
        ext = "scene.#{sc['id']}"
        ext = states.values.find { |s| s["entity_id"].start_with?("scene.") && s.dig("attributes", "id").to_s == sc["id"].to_s }&.dig("entity_id") || ext
        next if ExternalRef.find_by(site_id: @site.id, source: SOURCE, external_id: ext)&.target

        items, lost = scene_items(sc["entities"].to_h)
        scene = @site.scenes.create!(name: sc["name"], items: items, shadow: true) if items.any?
        link!(ext, "scene", scene, sc["name"], note: ("sem ponto equivalente" unless scene))
        @r.scenes << { "name" => sc["name"], "items" => items.size, "lost" => lost }
      end
    end

    # Estado da entidade na cena → linha (comando que o recoloca).
    def scene_items(entities)
      points = ExternalRef.map_for(@site, SOURCE, "Point")
      lost = []
      items = entities.filter_map do |entity, conf|
        state = conf.is_a?(Hash) ? conf["state"] : conf
        point = Point.find_by(id: points[entity]) or next lost.push(entity) && nil
        cmds = Points::Command.commands_for(point)
        if %w[on off].include?(state.to_s) && cmds.include?(state.to_s) then { "point_id" => point.id, "command" => state.to_s }
        elsif cmds.include?("set") then { "point_id" => point.id, "command" => "set", "value" => state }
        elsif cmds.include?("select") then { "point_id" => point.id, "command" => "select", "value" => state.to_s }
        else lost.push(entity) && nil
        end
      end
      [ items, lost ]
    end

    # Scripts (várias voltas: um script que chama outro espera o outro existir) e automações.
    def run_items!(domain, file)
      text = @files[file].to_s
      return if text.strip.empty?

      doc = YAML.safe_load(text, aliases: false)
      ids = domain == "automation" ? automation_ids : {}
      keys = doc.is_a?(Hash) ? doc.select { |_, v| v.is_a?(Hash) && v.key?("sequence") }.keys : []
      pending = Blueprints::HaImport.ha_items(doc).each_with_index.map do |(_, name, body), i|
        [ name, body, domain == "automation" ? ids[body["id"].to_s] : "script.#{keys[i]}" ]
      end
      3.times do
        break if pending.empty?

        pending = pending.reject { |name, body, ext| item!(domain, name, body, ext, last: false) }
      end
      pending.each { |name, body, ext| item!(domain, name, body, ext, last: true) }
    end

    def automation_ids
      registry("entity_registry", "entities").select { |e| e["platform"] == "automation" }.to_h { |e| [ e["unique_id"].to_s, e["entity_id"] ] }
    end

    # → true se resolveu (criou ou já existia).
    def item!(domain, name, body, ext, last:)
      ext ||= "#{domain}:#{name}"
      old = ExternalRef.find_by(site_id: @site.id, source: SOURCE, external_id: ext)&.target
      return true if old && old.published?

      # Rascunho de uma importação anterior (nunca rodou): refaz com o de-para de agora.
      old&.then { |a| [ a, a.blueprint ].compact.each(&:destroy!) }

      attrs = Blueprints::HaImport.new("", nil, entities: true).convert(Blueprints::HaImport.as_blueprint(domain, name, body))
      values, unresolved = resolve(attrs["inputs"])
      return false if unresolved.any? { |u| u.start_with?("script.") } && !last

      automation = create!(attrs, name, values, domain, ext)
      notes = attrs["unsupported"] + unresolved.map { |u| "sem de-para: #{u}" }
      notes << "rascunho: não publicou (#{automation.errors_in(automation.draft).first})" unless automation.published?
      link!(ext, domain, automation, name)
      @r.items << { "kind" => domain, "name" => name, "ref" => ext, "lossless" => notes.empty?, "notes" => notes, "enabled" => automation.enabled }
      true
    rescue Blueprints::HaImport::Error, ActiveRecord::RecordInvalid, ArgumentError => e
      @r.items << { "kind" => domain, "name" => name, "ref" => ext, "lossless" => false, "notes" => [ "não importou: #{e.message.truncate(150)}" ] } if last
      last
    end

    def create!(attrs, name, values, domain, ext)
      blueprint = @site.blueprints.create!(attrs.except("unsupported").merge("name" => name.truncate(120), "unsupported" => attrs["unsupported"]))
      automation = blueprint.create_automation!(name: name, values: values.compact, publish: true)
      on = domain == "automation" && automation.published? && states.dig(ext, "state") == "on"
      automation.update!(shadow: true, enabled: on)
      automation
    rescue ArgumentError
      # Falta entrada obrigatória: vira rascunho com o que deu.
      definition, clean, = blueprint.instantiate(values.compact)
      scope = domain == "script" ? @site.scripts : @site.automations
      scope.create!(name: name, mode: blueprint.mode, blueprint: blueprint, blueprint_inputs: clean, draft: definition, shadow: true)
    end

    # Entradas do blueprint → valores pelo de-para. Entrada de aparelho
    # ("Aparelho do HA 1a2b3c4d") casa pelo começo do id da entidade ou do aparelho.
    def resolve(inputs)
      refs = ExternalRef.where(site_id: @site.id, source: SOURCE).mapped.pluck(:external_id, :target_type, :target_id)
      unresolved = []
      values = Array(inputs).to_h do |input|
        label = input["label"].to_s
        prefix = label[/\AAparelho do HA (\h{8})/, 1]
        hit = if prefix then refs.find { |ext, type, _| type == "Point" && ext.start_with?("entity:#{prefix}") } || device_point(prefix, input)
        else refs.find { |ext, _, _| ext == label }
        end
        id = hit && (hit[1] == "Automation" ? Scripts.point_for(Automation.find(hit[2]))&.id : hit[2]) # script de lá → ponto do script daqui
        unresolved << label if id.nil? && %w[point scene].include?(input["type"])
        [ input["key"], id ]
      end
      [ values, unresolved ]
    end

    # Aparelho inteiro como alvo: o único ponto dele que passa no filtro da entrada.
    def device_point(prefix, input)
      ref = ExternalRef.where(site_id: @site.id, source: SOURCE, target_type: "Device").where("external_id LIKE ?", "device:#{prefix}%").first or return
      caps = Array(input.dig("filter", "capability"))
      list = Point.where(device_id: ref.target_id).select { |p| caps.empty? || caps.include?(p.capability) }
      list = list.select(&:writable) if input.dig("filter", "writable")
      [ nil, "Point", list.first.id ] if list.one?
    end
  end
end
