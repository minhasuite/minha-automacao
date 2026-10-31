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
  #
  # Lote 7: as etiquetas do HA (`label_registry`) viram etiquetas dos pontos;
  # os sensores template criados pela tela do HA (`config_entries`) viram
  # sensor calculado quando o Jinja traduz (`label_entities`/`area_entities`
  # → `count_points`); o conversor recebe as áreas, etiquetas, integrações e
  # os `rest_command` do `configuration`; e o item em rascunho ou publicado
  # com perda é refeito no lugar (mesmo id, mesma execução em sombra).
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
    # Classe do sensor do HA → capacidade daqui (Lote 8), também quando o aparelho tem um ponto só dela.
    CLASS_CAPS = { "motion" => "motion", "occupancy" => "motion", "presence" => "motion", "door" => "contact", "window" => "contact" }.freeze

    Result = Struct.new(:areas, :devices_added, :devices_moved, :entities, :unmapped, :helpers, :helpers_skipped, :scenes, :items, :tags, keyword_init: true)
    # Sensor template da tela do HA → tipo do sensor calculado daqui.
    TEMPLATE_KINDS = { "binary_sensor" => "bool", "sensor" => "number" }.freeze

    def self.call(site, files) = new(site, files).call

    def initialize(site, files)
      @site = site
      @files = files.transform_keys(&:to_s)
      @r = Result.new(areas: 0, devices_added: 0, devices_moved: 0, entities: 0, unmapped: [], helpers: 0, helpers_skipped: [], scenes: [], items: [], tags: 0)
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
    def entries = @entries ||= Array(json("config_entries")&.dig("data", "entries"))
    def labels = @labels ||= Array(json("label_registry")&.dig("data", "labels")).to_h { |l| [ l["label_id"], l["name"].to_s ] }

    # O `rest_command:` do configuration.yaml (os `!include`/`!secret` ficam vazios).
    def rest_commands
      text = @files["configuration"].to_s.gsub(/!(?:include\w*|secret|env_var)\b[^\n]*/, "null")
      YAML.safe_load(text, aliases: false).to_h["rest_command"].to_h
    rescue Psych::Exception
      {}
    end

    # Conversor do HA com o que a instalação sabe (áreas, etiquetas, integrações, rest_command).
    def converter(entity = nil)
      opts = { areas: @areas.transform_values(&:name), labels: labels, entries: entries.to_h { |c| [ c["entry_id"], c["domain"] ] } }
      return Blueprints::Jinja.new(entity, **opts) if entity

      Blueprints::HaImport.new("", nil, entities: true, rest_commands: (@rest ||= rest_commands), **opts)
    end

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
        tag!(point, e["labels"])
        @r.entities += 1
      end
      wanted = registry("entity_registry", "entities").select { |e| e["disabled_by"].blank? && e["device_id"] && @devices[e["device_id"]] }
      @r.unmapped = wanted.map { |e| e["entity_id"] } - ExternalRef.map_for(@site, SOURCE).keys
    end

    # Etiquetas do HA na entidade → etiquetas do ponto (pelo nome).
    def tag!(point, ids)
      Array(ids).filter_map { |id| labels[id].presence }.each do |name|
        tag = Tag.find_or_create_by!(name: name.downcase)
        @r.tags += 1 if Tagging.find_or_create_by!(tag: tag, taggable: point).previously_new_record?
      end
    end

    def point_for(e)
      uid = e["unique_id"].to_s
      device = @devices[e["device_id"]] || device_by_uid(uid) or return
      points = device.points.to_a
      by_code = points.select { |p| p.address["code"].present? && uid.end_with?(p.address["code"]) }.max_by { |p| p.address["code"].size }
      by_code || points.find { |p| p.address["dps"].present? && uid.end_with?("_#{p.address['dps']}") } ||
        (uid =~ /_p_(\d+)_(\d+)\z/ && points.find { |p| p.address["siid"].to_i == ::Regexp.last_match(1).to_i && p.address["piid"].to_i == ::Regexp.last_match(2).to_i }) ||
        (uid =~ /_e_(\d+)_(\d+)\z/ && points.find { |p| p.address["siid"].to_i == ::Regexp.last_match(1).to_i && p.address["eiid"].to_i == ::Regexp.last_match(2).to_i }) ||
        (cap = DOMAIN_CAPS[e["entity_id"].to_s.split(".").first] || CLASS_CAPS[e["original_device_class"] || e["device_class"]]) &&
          points.select { |p| p.capability == cap }.then { |l| l.first if l.one? }
    end

    # Lote 8: entidade sem aparelho no HA (integração própria, ex.: movimento
    # da câmera) cujo `unique_id` começa pelo id do aparelho daqui.
    def device_by_uid(uid)
      @by_ext ||= @site.devices.where.not(external_id: [ nil, "" ]).to_a.sort_by { |d| -d.external_id.size }
      @by_ext.find { |d| d.external_id.size >= 8 && uid.start_with?("#{d.external_id}_") }
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
      entries.select { |c| c["domain"] == "template" }.each { |c| template!(c) }
    end

    # Sensor template da tela do HA → sensor calculado (só se o Jinja traduz).
    def template!(c)
      o = c["options"].to_h
      kind = TEMPLATE_KINDS[o["template_type"]] or return
      ext = registry("entity_registry", "entities").find { |e| e["config_entry_id"] == c["entry_id"] }&.dig("entity_id") || "template:#{c['entry_id']}"
      return if ExternalRef.find_by(site_id: @site.id, source: SOURCE, external_id: ext)&.target

      ids = ExternalRef.map_for(@site, SOURCE, "Point")
      keys = Point.where(id: ids.values).pluck(:id, :key).to_h
      expr = converter(->(e) { keys[ids[e]] }).expr(o["state"].to_s)&.gsub(/\[\[([^\]]+)\]\]/, '\1')
      return @r.helpers_skipped << "#{ext}: template sem tradução" unless expr

      helper!({ "entity_id" => ext, "attributes" => { "friendly_name" => o["name"].presence || c["title"] } }, "template",
              { "kind" => kind, "expr" => expr, "unit" => o["unit_of_measurement"] })
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

    # → true se resolveu (criou, refez ou já existia).
    def item!(domain, name, body, ext, last:)
      ext ||= "#{domain}:#{name}"
      old = ExternalRef.find_by(site_id: @site.id, source: SOURCE, external_id: ext)&.target
      # Publicada sem perda fica como está (pode ter sido revisada). Rascunho
      # ou com perda: refaz no lugar com o de-para e o conversor de agora.
      return true if old&.published? && old.blueprint && Array(old.blueprint.unsupported).empty? && !old.draft?

      attrs = converter.convert(Blueprints::HaImport.as_blueprint(domain, name, body))
      values, unresolved = resolve(attrs["inputs"])
      return false if unresolved.any? { |u| u.start_with?("script.") } && !last

      automation = old ? refresh!(old, attrs, name, values, domain, ext) : create!(attrs, name, values, domain, ext)
      notes = attrs["unsupported"] + unresolved.map { |u| "sem de-para: #{u}" } + attribute_notes(automation)
      notes << "rascunho: não publicou (#{automation.errors_in(automation.draft).first || 'falta entrada sem de-para'})" if automation.draft?
      link!(ext, domain, automation, name)
      @r.items << { "kind" => domain, "name" => name, "ref" => ext, "lossless" => notes.empty?, "notes" => notes, "enabled" => automation.enabled }
      true
    rescue Blueprints::HaImport::Error, ActiveRecord::RecordInvalid, ArgumentError => e
      @r.items << { "kind" => domain, "name" => name, "ref" => ext, "lossless" => false, "notes" => [ "não importou: #{e.message.truncate(150)}" ] } if last
      last
    end

    # Lote 8: gatilho por atributo que o ponto daqui (ainda) não informa: converte, mas não dispara.
    def attribute_notes(automation)
      Array((automation.draft || automation.definition).to_h["triggers"]).filter_map do |t|
        p = t["attribute"].present? && Point.find_by(id: t["point"])
        "o ponto #{p.name} não informa o atributo #{t['attribute']} (o gatilho não dispara)" if p && !p.attrs.to_h.key?(t["attribute"])
      end
    end

    def blueprint_attrs(attrs, name) = attrs.except("unsupported").merge("name" => name.truncate(120), "unsupported" => attrs["unsupported"])
    # Ligada só se publicou nesta importação (sem rascunho pendente) e está ligada no HA.
    def enabled?(automation, domain, ext) = domain == "automation" && automation.published? && !automation.draft? && states.dig(ext, "state") == "on"

    def create!(attrs, name, values, domain, ext)
      blueprint = @site.blueprints.create!(blueprint_attrs(attrs, name))
      automation = blueprint.create_automation!(name: name, values: values.compact, publish: true)
      automation.update!(shadow: true, enabled: enabled?(automation, domain, ext))
      automation
    rescue ArgumentError
      # Falta entrada obrigatória: vira rascunho com o que deu.
      definition, clean, = blueprint.instantiate(values.compact)
      scope = domain == "script" ? @site.scripts : @site.automations
      scope.create!(name: name, mode: blueprint.mode, blueprint: blueprint, blueprint_inputs: clean, draft: definition, shadow: true)
    end

    # Refaz no lugar: o blueprint muda, o rascunho é refeito e publica se a DSL fechar.
    def refresh!(automation, attrs, name, values, domain, ext)
      blueprint = automation.blueprint
      blueprint ? blueprint.update!(blueprint_attrs(attrs, name)) : (blueprint = @site.blueprints.create!(blueprint_attrs(attrs, name)))
      definition, clean, errors = blueprint.instantiate(values.compact)
      automation.assign_attributes(blueprint: blueprint, blueprint_inputs: clean, draft: definition, shadow: true, mode: blueprint.mode)
      if errors.empty? && automation.errors_in(definition).empty? then automation.publish!(definition)
      else automation.save!(validate: false) # a versão publicada pode ter ficado inválida (ponto sumiu); o rascunho novo fica para revisar
      end
      automation.update_column(:enabled, enabled?(automation, domain, ext)) # rubocop:disable Rails/SkipsModelValidations
      automation
    end

    # Entradas do blueprint → valores pelo de-para. Entrada de aparelho
    # ("Aparelho do HA 1a2b3c4d") casa pelo começo do id da entidade ou do aparelho.
    def resolve(inputs)
      refs = ExternalRef.where(site_id: @site.id, source: SOURCE).mapped.pluck(:external_id, :target_type, :target_id)
      unresolved = []
      values = Array(inputs).to_h do |input|
        label, cap = input["label"].to_s.split("#", 2) # Lote 8: "light.x#color" = ponto irmão do aparelho
        prefix = label[/\AAparelho do HA (\h{8})/, 1]
        hit = if prefix then (refs.find { |ext, type, _| type == "Point" && ext.start_with?("entity:#{prefix}") } unless cap) || device_point(prefix, input)
        else refs.find { |ext, _, _| ext == label }
        end
        hit = sibling(hit, input) if cap && hit && !prefix
        id = hit && (hit[1] == "Automation" ? Scripts.point_for(Automation.find(hit[2]))&.id : hit[2]) # script de lá → ponto do script daqui
        unresolved << label if id.nil? && %w[point scene].include?(input["type"])
        [ input["key"], id ]
      end
      [ values, unresolved ]
    end

    # Ponto irmão: o único do mesmo aparelho que passa no filtro da entrada.
    def sibling(hit, input)
      point = hit[1] == "Point" && Point.find_by(id: hit[2]) or return
      caps = Array(input.dig("filter", "capability"))
      list = Point.where(device_id: point.device_id).select { |p| caps.include?(p.capability) && p.writable }
      [ nil, "Point", list.first.id ] if list.one?
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
