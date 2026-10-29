module Automations
  # Operações do editor visual no rascunho: cada bloco (gatilho, condição,
  # ação, opção) tem um caminho ("actions.2.then.0") e o formulário dele
  # manda os campos como texto; aqui viram o JSON da DSL pelo tipo do campo
  # (Dsl::TRIGGERS/CONDITIONS/ACTIONS). Bloco pela metade pode ficar no
  # rascunho: a validação completa barra só a publicação.
  class Editor
    # Nome da lista → tipo de bloco que ela aceita.
    LISTS = { "triggers" => :triggers, "conditions" => :conditions, "while" => :conditions, "until" => :conditions,
              "actions" => :actions, "then" => :actions, "else" => :actions, "default" => :actions, "options" => :options }.freeze
    # O bloco já nasce com o que costuma ser usado (e passa na validação quando dá).
    DEFAULTS = {
      triggers: { "time" => { "at" => "18:00" }, "sun" => { "event" => "sunset" }, "alert" => { "on" => "open" } },
      conditions: { "time" => { "after" => "18:00" }, "sun" => { "after" => "sunset" }, "expr" => { "expr" => "hour >= 18" } },
      actions: { "command" => { "command" => "on" }, "notify" => { "channels" => Notifier::CHANNELS.keys, "title" => "Aviso" },
                 "wait" => { "for" => "1m" }, "wait_for" => { "conditions" => [], "timeout" => "5m" },
                 "choose" => { "options" => [ { "conditions" => [], "actions" => [] } ] }, "repeat" => { "count" => 2 } }
    }.freeze

    attr_reader :definition

    def initialize(definition, site)
      @definition = definition.deep_dup.presence || Dsl.empty
      @site = site
    end

    def self.list_kind(path) = LISTS.fetch(path.to_s.split(".").last) { raise KeyError, "lista" }

    # Novo bloco no fim da lista; devolve o caminho dele.
    def add(list_path, type)
      kind = self.class.list_kind(list_path)
      node = kind == :options ? { "conditions" => [], "actions" => [] } : new_block(kind, type)
      list = list_at(list_path, create: true)
      list << node
      "#{list_path}.#{list.size - 1}"
    end

    # Campos do formulário (texto) → valores do bloco. Campo vazio some.
    def update(path, form)
      node = dig(path)
      kind = self.class.list_kind(path.split(".")[0..-2].join("."))
      spec = Dsl.spec(kind, node["type"]) or raise KeyError, "tipo"
      form = form.to_h.stringify_keys
      point = @site.points.find_by(id: node["point"]) if node["point"]
      spec[:fields].each do |fd|
        next if Dsl::LIST_KINDS.key?(fd.kind) || !form.key?(fd.name)

        value = cast(fd, form[fd.name], point)
        point = @site.points.find_by(id: value) if fd.kind.in?(%i[point writable_point])
        value.nil? ? node.delete(fd.name) : node[fd.name] = value
      end
      path
    end

    def move(path, dir)
      list, i = parent(path)
      j = dir == "up" ? i - 1 : i + 1
      return path unless j.between?(0, list.size - 1)

      list[i], list[j] = list[j], list[i]
      path.sub(/\d+\z/, j.to_s)
    end

    def remove(path)
      list, i = parent(path)
      list.delete_at(i)
    end

    private

    def new_block(kind, type)
      Dsl.spec(kind, type) or raise KeyError, "tipo"
      { "type" => type }.merge(DEFAULTS.dig(kind, type).to_h.deep_dup)
    end

    def cast(fd, raw, point)
      raw = raw.compact_blank if raw.is_a?(Array)
      return nil if raw.blank? && raw != false

      case fd.kind
      when :number then Float(raw.to_s.tr(",", "."), exception: false)&.then { |n| n % 1 == 0 ? n.to_i : n } || raw
      when :value then point ? point.cast(raw.to_s) : raw
      when :bool then ActiveModel::Type::Boolean.new.cast(raw)
      when :days
        days = Array(raw).map(&:to_i).uniq.sort
        days.size == 7 ? nil : days
      when :channels then Array(raw)
      else raw.to_s.strip.presence
      end
    end

    def parent(path)
      parts = path.split(".")
      list = list_at(parts[0..-2].join("."))
      i = Integer(parts.last)
      raise KeyError, "bloco" unless list && i < list.size

      [ list, i ]
    end

    def list_at(path, create: false)
      parts = path.split(".")
      holder = parts.size == 1 ? @definition : dig(parts[0..-2].join("."))
      raise KeyError, "lista" unless holder.is_a?(Hash)

      holder[parts.last] = [] if create && !holder[parts.last].is_a?(Array)
      holder[parts.last]
    end

    def dig(path)
      path.split(".").reduce(@definition) do |node, part|
        next_node = node.is_a?(Array) ? node[Integer(part)] : node.fetch(part)
        raise KeyError, path if next_node.nil?

        next_node
      end
    rescue ArgumentError, TypeError, IndexError
      raise KeyError, path
    end
  end
end
