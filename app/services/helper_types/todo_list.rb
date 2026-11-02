module HelperTypes
  # Lista de tarefas (todo local do HA, ondaA1 A11): itens em
  # `attrs["items"]` ([{uid, summary, status, due, description}], status
  # needs_action/completed); o valor é quantos faltam. Comandos (painel,
  # automação, voz, API): adicionar, concluir, reabrir, remover e limpar os
  # concluídos, com o texto do item (ou o uid) como valor. A tela Listas do
  # local mostra e edita todas.
  class TodoList < Plugin
    MAX_ITEMS = 500
    COMMANDS = %w[add_item complete_item reopen_item remove_item clear_completed].freeze

    describe key: "todo", title: "Lista de tarefas", icon: "clipboard-list", capability: "todo",
             description: "Lista compartilhada (compras, tarefas da casa): adicione pela tela, pela voz ou por automação e marque o que já foi."
    texts "pt-BR" => { "cmd.add_item" => "Adicionar item", "cmd.complete_item" => "Concluir item", "cmd.reopen_item" => "Reabrir item",
                       "cmd.remove_item" => "Remover item", "cmd.clear_completed" => "Limpar concluídos", empty: "Informe o item.", full: "A lista já tem %{max} itens.",
                       missing: "Item \"%{item}\" não está na lista.", pending: "%{n} a fazer", summary: "%{n} itens" },
          en: { title: "To-do list", description: "Shared list (shopping, chores): add from the screen, by voice or by automation and check what is done.",
                "cmd.add_item" => "Add item", "cmd.complete_item" => "Complete item", "cmd.reopen_item" => "Reopen item",
                "cmd.remove_item" => "Remove item", "cmd.clear_completed" => "Clear completed", empty: "Enter the item.", full: "The list already has %{max} items.",
                missing: "Item \"%{item}\" is not on the list.", pending: "%{n} to do", summary: "%{n} items" },
          es: { title: "Lista de tareas", description: "Lista compartida (compras, tareas de la casa): agrega desde la pantalla, por voz o por automatización y marca lo hecho.",
                "cmd.add_item" => "Agregar ítem", "cmd.complete_item" => "Completar ítem", "cmd.reopen_item" => "Reabrir ítem",
                "cmd.remove_item" => "Quitar ítem", "cmd.clear_completed" => "Limpiar completados", empty: "Indica el ítem.", full: "La lista ya tiene %{max} ítems.",
                missing: "El ítem \"%{item}\" no está en la lista.", pending: "%{n} por hacer", summary: "%{n} ítems" }

    def self.assign(point, _form)
      point.data_type = "integer"
      point.writable = true
    end

    def self.initial_value(_point) = 0
    def self.commands(_point) = COMMANDS
    def self.command_labels = COMMANDS.index_with { |c| text("cmd.#{c}") }
    def self.items(point) = Array(point.attrs.to_h["items"])
    def self.pending(point) = items(point).count { |i| i["status"] != "completed" }
    def self.value_text(point) = text(:pending, n: pending(point))
    def self.summary(point) = text(:summary, n: items(point).size)

    # O valor é o texto do item (ou o uid); limpar não leva valor.
    def self.new_value(cmd)
      return pending(cmd.point) if cmd.command == "clear_completed"
      raise Points::Command::Error.new(:invalid_value, text(:empty)) if cmd.value.to_s.strip.empty?

      pending(cmd.point)
    end

    def self.execute(point, command, value)
      list = items(point).map(&:dup)
      ref = value.is_a?(Hash) ? value["summary"] || value["uid"] : value.to_s.strip
      case command
      when "add_item"
        raise Points::Command::Error.new(:invalid_value, text(:full, max: MAX_ITEMS)) if list.size >= MAX_ITEMS

        extra = value.is_a?(Hash) ? value.slice("due", "description").compact_blank : {}
        list << { "uid" => SecureRandom.uuid, "summary" => ref.to_s.first(255), "status" => "needs_action" }.merge(extra)
      when "clear_completed" then list.reject! { |i| i["status"] == "completed" }
      else
        item = find(list, ref) or raise Points::Command::Error.new(:invalid_value, text(:missing, item: ref))
        case command
        when "complete_item" then item["status"] = "completed"
        when "reopen_item" then item["status"] = "needs_action"
        when "remove_item" then list.delete(item)
        end
      end
      point.report_attrs!(point.attrs.to_h.merge("items" => list))
      point.report!(list.count { |i| i["status"] != "completed" })
    end

    # Pelo uid ou pelo texto (sem caixa e acento; o pendente primeiro).
    def self.find(list, ref)
      key = I18n.transliterate(ref.to_s).downcase.strip
      list.find { |i| i["uid"] == ref } ||
        list.sort_by { |i| i["status"] == "completed" ? 1 : 0 }.find { |i| I18n.transliterate(i["summary"].to_s).downcase.strip == key }
    end
  end
end
