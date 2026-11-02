module Assist
  module Intents
    # Listas de tarefas da ondaA1 (A11; HassListAddItem, HassListCompleteItem,
    # HassShoppingListAddItem): a lista pelo nome curto ("compras") ou apelido.
    module Lists
      def self.allowed?(ctx, list) = SiteMembership.allowed?(ctx.role, :command, risk: list.risk)

      class Add < Intent
        describe key: "todo_add", slots: %w[item list],
                 description: "Coloca um item numa lista de tarefas (compras, tarefas...).",
                 sentences: { "pt-BR" => [ "(adicionar|adicione|adiciona|colocar|coloque|coloca|incluir|inclua|inclui|por|ponha|poe|bota|bote|anotar|anote|anota) {item} (a|na|no|em|nas|as) [minha] {list}" ],
                              "en" => [ "add {item} to [my|the] {list}", "put {item} on [my|the] {list}" ],
                              "es" => [ "(agrega|agregar|anade|anadir|pon|poner|anota|anotar|apunta) {item} (a|en) [mi|la] {list}" ] }
        texts "pt-BR" => { done: "Coloquei %{item} em %{list}.", denied: "Por voz não posso mexer em %{list}.", slots: { item: "O item", list: "Nome da lista" } },
              en: { description: "Adds an item to a to-do list (shopping, chores...).", done: "Added %{item} to %{list}.", denied: "I can't change %{list} by voice.",
                    slots: { item: "The item", list: "List name" } },
              es: { description: "Agrega un elemento a una lista de tareas (compras, tareas...).", done: "Agregué %{item} a %{list}.", denied: "Por voz no puedo cambiar %{list}.",
                    slots: { item: "El elemento", list: "Nombre de la lista" } }

        def self.handle(ctx, slots)
          list = Assist.find_list(ctx.site, slots["list"].to_s) or return
          return reply(text(:denied, list: list.name)) unless Lists.allowed?(ctx, list)

          item = Assist.original(ctx.heard, slots["item"].to_s).sub(/\A(?:o|a|os|as|um|uma|the|some|el|la|los|las|un|una)\s+/i, "")
          Points::Command.call(list, "add_item", item, source: "voice", user: ctx.user)
          reply(text(:done, item: item, list: list.name), points: [ list ])
        end
      end

      class Complete < Intent
        describe key: "todo_complete", slots: %w[item list],
                 description: "Marca um item da lista como feito.",
                 sentences: { "pt-BR" => [ "(marcar|marque|marca|riscar|risque|risca|concluir|conclua|conclui|tirar|tire|tira|remover|remova|remove) {item} (da|na|no|do|de|das) [minha] {list}" ],
                              "en" => [ "(check off|cross off|complete|mark|remove) {item} (on|from|in) [my|the] {list} [as done|as complete]" ],
                              "es" => [ "(marca|marcar|tacha|tachar|quita|quitar|completa|completar) {item} (de|en) [mi|la] {list}" ] }
        texts "pt-BR" => { done: "Marquei %{item} em %{list}.", missing: "%{item} não está em %{list}.", denied: "Por voz não posso mexer em %{list}." },
              en: { description: "Marks a list item as done.", done: "Checked off %{item} on %{list}.", missing: "%{item} isn't on %{list}.",
                    denied: "I can't change %{list} by voice." },
              es: { description: "Marca un elemento de la lista como hecho.", done: "Marqué %{item} en %{list}.", missing: "%{item} no está en %{list}.",
                    denied: "Por voz no puedo cambiar %{list}." }

        def self.handle(ctx, slots)
          list = Assist.find_list(ctx.site, slots["list"].to_s) or return
          return reply(text(:denied, list: list.name)) unless Lists.allowed?(ctx, list)

          item = Assist.original(ctx.heard, slots["item"].to_s)
          c = Points::Command.call(list, "complete_item", item, source: "voice", user: ctx.user)
          reply(text(c.error ? :missing : :done, item: item, list: list.name), points: [ list ])
        rescue Points::Command::Error
          reply(text(:missing, item: item, list: list.name), points: [ list ])
        end
      end

      class Read < Intent
        describe key: "todo_read", slots: %w[list],
                 description: "Lê os itens que faltam numa lista.",
                 sentences: { "pt-BR" => [ "(o que tem|que tem|ler|leia|le|mostrar|mostre|mostra) [na|a|no|o] {list}" ],
                              "en" => [ "what (is|s) on [my|the] {list}", "read [my|the] {list}" ],
                              "es" => [ "que hay en [mi|la] {list}", "(lee|leer|muestra) [mi|la] {list}" ] }
        texts "pt-BR" => { empty: "%{list} está vazia.", items: "Em %{list}: %{items}." },
              en: { description: "Reads the pending items of a list.", empty: "%{list} is empty.", items: "On %{list}: %{items}." },
              es: { description: "Lee los elementos pendientes de una lista.", empty: "%{list} está vacía.", items: "En %{list}: %{items}." }

        def self.handle(ctx, slots)
          list = Assist.find_list(ctx.site, slots["list"].to_s) or return
          items = HelperTypes::TodoList.items(list).reject { |i| i["status"] == "completed" }.pluck("summary")
          reply(items.empty? ? text(:empty, list: list.name) : text(:items, list: list.name, items: Assist.list(items.first(20))), points: [ list ])
        end
      end
    end
  end
end
