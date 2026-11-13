module Devices
  # "Substituir aparelho" (docs/integracoes.md): troca o aparelho físico (ou o
  # caminho até ele: hub Tuya → coordenador Zigbee próprio) sem refazer nada.
  # Para cada par ponto antigo → ponto novo, o PONTO ANTIGO fica (id, chave,
  # nome, área, risco, histórico, painéis, automações, cenas, ligações, avisos,
  # helpers, de-para) e passa a pertencer ao aparelho novo com o endereço do
  # ponto novo; o ponto novo (duplicado) é apagado. Como o id não muda, nada que
  # aponta para o ponto precisa mudar. Vale para qualquer driver.
  #
  # Sugestão de pares por dado (`config/device_replace.yml`): capacidade,
  # device_class, unidade, nome e propriedade equivalente (`doorcontact_state`
  # ↔ `contact`). "Inverter" é o campo genérico `address.invert`
  # (`Points::Decode.invert`), sugerido quando o sentido do verdadeiro difere.
  #
  # Tudo numa transação; vira AuditEvent `device.replace` com o antes de cada
  # ponto, o que permite o "desfazer" (`undo!`).
  class Replace
    class Error < StandardError; end

    ACTION = "device.replace".freeze
    UNDO_ACTION = "device.replace_undo".freeze
    RETIRE = %w[remove disable keep].freeze
    # O que o ponto antigo recebe do novo (é do aparelho/driver, não da pessoa).
    TAKE = %w[address scale offset writable data_type unit min max step].freeze
    # Ajustes da pessoa guardados no endereço: continuam com o ponto antigo.
    KEEP_ADDRESS = %w[stale_open_s notify_s].freeze
    # O que o "desfazer" devolve ao ponto antigo.
    RESTORE = (TAKE + %w[device_id area_id options display_unit]).freeze
    MIN_SCORE = 4

    Pair = Struct.new(:old, :new, :invert, keyword_init: true)

    def self.data = @data ||= YAML.load_file(Rails.root.join("config/device_replace.yml"))
    def self.alias_groups = data.fetch("aliases").map { |g| g.map { |s| s.to_s.downcase } }
    def self.closed_when_true = data.fetch("closed_when_true").map(&:to_s)

    # Aparelhos que podem receber os pontos: do mesmo local, ativos, fora os internos.
    def self.candidates(device)
      device.site.devices.listed.where(removed_at: nil).where.not(id: device.id).order(:name)
    end

    # Propriedade do endereço (dp Tuya, json_path, propriedade MIoT…), último trecho.
    def self.property(point)
      a = point.address.to_h
      %w[code json_path property field key dps].each { |k| return a[k].to_s.split(".").last.downcase if a[k].present? }
      nil
    end

    # Ponto bool: verdadeiro quer dizer aberto/ativo? (nil = não é bool)
    def self.true_is_active?(point)
      return unless point.bool?

      a = point.address.to_h
      raw_true_active = !closed_when_true.include?(property(point))
      on = a.key?("payload_on") ? a["payload_on"] : true
      active = on == false ? !raw_true_active : raw_true_active
      a["invert"] ? !active : active
    end

    def self.suggest_invert?(old_point, new_point)
      a, b = true_is_active?(old_point), true_is_active?(new_point)
      !a.nil? && !b.nil? && a != b
    end

    def self.compatible?(old_point, new_point)
      return false if old_point.helper.present? || new_point.helper.present?

      dt = [ old_point.data_type, new_point.data_type ]
      dt.uniq.size == 1 || dt.all? { |t| t.in?(%w[integer decimal]) } || dt.all? { |t| t.in?(%w[enum string]) }
    end

    def self.score(old_point, new_point)
      return 0 unless compatible?(old_point, new_point)

      s = 0
      s += 4 if old_point.capability == new_point.capability
      s += 2 if old_point.data_type == new_point.data_type
      s += 3 if old_point.device_class.present? && old_point.device_class.casecmp?(new_point.device_class.to_s)
      s += 2 if old_point.unit.present? && old_point.unit == new_point.unit
      po, pn = property(old_point), property(new_point)
      s += 5 if po && pn && (po == pn || alias_groups.any? { |g| g.include?(po) && g.include?(pn) })
      s += 3 if I18n.transliterate(old_point.name).casecmp?(I18n.transliterate(new_point.name))
      s += 1 if s.positive? && Point.covered?(new_point.name, old_point.name)
      s
    end

    def self.points_of(device) = device.points.where(helper: nil).ordered.to_a

    # → [Pair] um por ponto antigo (new nil = sem par), escolha gulosa pela maior nota.
    def self.suggest(old_device, new_device)
      olds, news = points_of(old_device), points_of(new_device)
      scored = olds.product(news).map { |o, n| [ score(o, n), o, n ] }.select { |s, _, _| s >= MIN_SCORE }
      taken, chosen = Set.new, {}
      scored.sort_by { |s, o, n| [ -s, o.name, n.name ] }.each do |_, o, n|
        next if chosen.key?(o.id) || taken.include?(n.id)

        chosen[o.id] = n
        taken << n.id
      end
      olds.map { |o| Pair.new(old: o, new: chosen[o.id], invert: chosen[o.id] ? suggest_invert?(o, chosen[o.id]) : false) }
    end

    # Pares vindos da tela/API: { "map" => { old_id => new_id }, "invert" => [old_id…] }
    # ou { "pairs" => [{ "old" =>, "new" =>, "invert" => }] }.
    def self.pairs_from(old_device, new_device, params)
      params = params.to_h.stringify_keys
      list = if params["pairs"].present?
        Array(params["pairs"]).map { |p| p.to_h.stringify_keys }.map { |p| [ p["old"], p["new"], ActiveModel::Type::Boolean.new.cast(p["invert"]) ] }
      else
        inv = Array(params["invert"].is_a?(Hash) ? params["invert"].select { |_, v| ActiveModel::Type::Boolean.new.cast(v) }.keys : params["invert"]).map(&:to_s)
        params["map"].to_h.map { |o, n| [ o, n, inv.include?(o.to_s) ] }
      end
      olds = points_of(old_device).index_by(&:id)
      news = points_of(new_device).index_by(&:id)
      used = Set.new
      list.filter_map do |o, n, inv|
        next if n.blank?

        old_point = olds[o.to_s] or raise Error, I18n.t("devices.replace.errors.old_point")
        new_point = news[n.to_s] or raise Error, I18n.t("devices.replace.errors.new_point")
        raise Error, I18n.t("devices.replace.errors.twice", name: new_point.name) unless used.add?(new_point.id)
        raise Error, I18n.t("devices.replace.errors.incompatible", old: old_point.name, new: new_point.name) unless compatible?(old_point, new_point)

        Pair.new(old: old_point, new: new_point, invert: inv && old_point.bool? ? true : false)
      end
    end

    # Prévia: o que muda, sem gravar.
    def self.preview(old_device, new_device, pairs, retire: "remove")
      mapped_old = pairs.map { |p| p.old.id }
      mapped_new = pairs.map { |p| p.new.id }
      {
        pairs: pairs.map do |p|
          { old: p.old, new: p.new, invert: p.invert, usages: Point.usages(p.old.site, Point.where(id: p.old.id)).size,
            new_usages: Point.usages(p.new.site, Point.where(id: p.new.id)).map(&:first) }
        end,
        old_left: points_of(old_device).reject { |pt| pt.id.in?(mapped_old) },
        new_left: points_of(new_device).reject { |pt| pt.id.in?(mapped_new) },
        retire: retire_for(old_device, pairs, retire)
      }
    end

    # remove: removido (`removed_at`) só se não sobrar ponto; senão desativado. disable/keep: como escolhido.
    def self.retire_for(old_device, pairs, retire)
      retire = "remove" unless retire.to_s.in?(RETIRE)
      return retire unless retire == "remove"

      left = old_device.points.where.not(id: pairs.map { |p| p.old.id }).exists?
      left ? "disable" : "remove"
    end

    # take_name: o aparelho novo fica com o nome do antigo (no zigbee2mqtt o nome
    # vai também para a ponte, `Pairing.renamed`).
    def self.call(old_device, new_device, pairs, user:, retire: "remove", take_name: false)
      new(old_device, new_device, pairs, user: user, retire: retire, take_name: take_name).call
    end

    def initialize(old_device, new_device, pairs, user:, retire:, take_name: false)
      @old_device, @new_device, @pairs, @user, @take_name = old_device, new_device, pairs, user, take_name
      @retire = self.class.retire_for(old_device, pairs, retire)
    end

    def call
      raise Error, I18n.t("devices.replace.errors.same_site") if @old_device.site_id != @new_device.site_id || @old_device.id == @new_device.id
      raise Error, I18n.t("devices.replace.errors.empty") if @pairs.empty?

      event = nil
      Device.transaction do
        entries = @pairs.map { |p| move!(p) }
        before = { "removed_at" => @old_device.removed_at&.iso8601, "disabled" => @old_device.disabled }
        case @retire
        when "remove" then @old_device.update!(removed_at: Time.current)
        when "disable" then @old_device.update!(disabled: true)
        end
        event = AuditEvent.create!(tenant_id: @old_device.tenant_id, user_id: @user&.id, action: ACTION, auditable_type: "Device", auditable_id: @old_device.id,
                                   details: { "new_device_id" => @new_device.id, "new_device_name" => @new_device.name, "old_device_name" => @old_device.name,
                                              "retire" => @retire, "device_before" => before, "pairs" => entries })
      end
      @pairs.each { |p| Points::Broadcast.changed(p.old.reload, grouped: false) }
      @new_device.update(name: @old_device.name) if @take_name && @new_device.name != @old_device.name
      resolve_joins
      event
    end

    # Assistente de pareamento: o aparelho que entrou e substituiu fica decidido.
    def resolve_joins
      PairingJoin.where(device_id: @new_device.id, resolution: nil).find_each do |j|
        j.update!(resolution: "replaced", resolved_at: Time.current,
                  details: j.details.merge("replaced_device_id" => @old_device.id, "replaced_device_name" => @old_device.name))
      end
    end

    # Desfaz a última substituição do aparelho antigo: os pontos voltam com o
    # endereço de antes e os pontos novos apagados são recriados (mesmo id).
    def self.undo!(event, user:)
      raise Error, I18n.t("devices.replace.errors.undone") if event.action != ACTION || event.details["undone_at"].present?

      old_device = Device.find(event.auditable_id)
      Device.transaction do
        event.details.fetch("pairs").each do |e|
          point = Point.find_by(id: e["old_point_id"]) or next
          point.update!(e["before"].slice(*RESTORE))
          attrs = e["new_point"]
          next if Point.exists?(id: attrs["id"]) || !Device.exists?(id: attrs["device_id"])

          attrs = attrs.merge("key" => free_key(point.site, attrs["key"]))
          Point.create!(attrs)
        end
        PairingJoin.where(resolution: "replaced").where("details->>'replaced_device_id' = ?", old_device.id).update_all(resolution: nil, resolved_at: nil)
        b = event.details["device_before"].to_h
        old_device.update!(removed_at: b["removed_at"], disabled: b["disabled"] ? true : false)
        event.update!(details: event.details.merge("undone_at" => Time.current.iso8601, "undone_by" => user&.id))
        AuditEvent.create!(tenant_id: event.tenant_id, user_id: user&.id, action: UNDO_ACTION, auditable_type: "Device", auditable_id: old_device.id,
                           details: { "replace_event_id" => event.id })
      end
      old_device
    end

    def self.free_key(site, key)
      return key unless site.points.exists?(key: key)

      (2..).lazy.map { |i| "#{key}_#{i}" }.find { |k| !site.points.exists?(key: k) }
    end

    # Última substituição que ainda pode ser desfeita.
    def self.last_event(device)
      AuditEvent.where(tenant_id: device.tenant_id, action: ACTION, auditable_type: "Device", auditable_id: device.id)
                .where("NOT (details ? 'undone_at')").order(created_at: :desc).first
    end

    private

    def move!(pair)
      old_point, new_point = pair.old, pair.new
      before = old_point.attributes.slice(*RESTORE)
      new_attrs = new_point.attributes.except("created_at", "updated_at", "value", "quality", "changed_at", "reported_at")
      take = new_point.attributes.slice(*TAKE)
      address = take["address"].to_h.merge(old_point.address.to_h.slice(*KEEP_ADDRESS))
      address = pair.invert ? address.merge("invert" => !address["invert"]) : address
      address.delete("invert") unless address["invert"]
      value = new_point.reported_at ? Points::Decode.flip(new_point.value, pair.invert) : old_point.value
      new_point.destroy!
      attrs = take.merge("address" => address, "device_id" => @new_device.id, "area_id" => old_point.effective_area_id)
      attrs["data_type"] = take["data_type"].presence || old_point.data_type
      attrs["options"] = new_point.options if new_point.option_values.any? && old_point.capability.in?(%w[enum vacuum gate weather])
      attrs["display_unit"] = nil if old_point.display_unit && !Units.compatible(attrs["unit"]).include?(old_point.display_unit)
      old_point.assign_attributes(attrs)
      old_point.value = value
      old_point.quality = new_point.quality if new_point.reported_at
      old_point.save!
      { "old_point_id" => old_point.id, "old_point_name" => old_point.name, "new_point_id" => new_point.id, "new_point_name" => new_point.name,
        "invert" => pair.invert, "before" => before, "new_point" => new_attrs }
    end
  end
end
