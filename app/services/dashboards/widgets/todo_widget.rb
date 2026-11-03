module Dashboards
  module Widgets
    # Lista de tarefas (ondaB2 B10; o `todo-list` do HA): itens do helper
    # Lista (HelperTypes::TodoList) com marcar/desmarcar, adicionar, remover e
    # limpar os concluídos, pelos comandos do ponto.
    class TodoWidget < Base
      LIMIT = 30
      describe type: "todo", label: "Lista de tarefas", icon: "clipboard-list", required: %w[bind], params: %w[hide_completed], bind: true
      texts en: { label: "To-do list", done: "Completed (%{n})", empty: "Nothing to do.", add: "Add item", clear: "Clear completed" },
            es: { label: "Lista de tareas", done: "Completados (%{n})", empty: "Nada por hacer.", add: "Agregar ítem", clear: "Limpiar completados" },
            "pt-BR" => { done: "Concluídos (%{n})", empty: "Nada a fazer.", add: "Adicionar item", clear: "Limpar concluídos" }

      def self.form = "web/dashboards/widget_forms/cards"

      def self.data(_r, w, binds)
        p = binds.first
        return [ { "point_ids" => [], "missing" => true }, [] ] unless p&.capability == "todo"

        items = HelperTypes::TodoList.items(p).map { |i| i.slice("uid", "summary", "status", "due") }
        pending, done = items.partition { |i| i["status"] != "completed" }
        [ { "point_ids" => [ p.id ], "pending" => pending.first(LIMIT), "done" => (w["hide_completed"] == "1" ? [] : done.first(LIMIT)), "done_count" => done.size,
            "done_label" => text(:done, n: done.size), "empty" => text(:empty), "add_label" => text(:add), "clear_label" => text(:clear) }, [] ]
      end
    end
  end
end
