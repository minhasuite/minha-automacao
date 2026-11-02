module Web
  # Listas de tarefas do local (ondaA1, A11; o todo do HA): todas as listas
  # (helpers "todo") numa tela, com adicionar, marcar e remover. Tudo passa
  # pelo comando do ponto (Points::Command), como na automação e na voz.
  class TodoListsController < ApplicationController
    before_action -> { @site = Site.find(params[:site_id]) }

    def index
      authorize_site!(@site, :view)
      @lists = @site.points.helpers.where(helper: HelperTypes::TodoList.key).ordered.to_a
    end

    def add = run("add_item", params[:summary].to_s.strip)
    def toggle = run(item_done? ? "reopen_item" : "complete_item", params[:uid])
    def remove = run("remove_item", params[:uid])
    def clear = run("clear_completed", nil)

    private

    def list = @list ||= @site.points.helpers.where(helper: HelperTypes::TodoList.key).find(params[:id])
    def item_done? = HelperTypes::TodoList.items(list).find { |i| i["uid"] == params[:uid] }&.dig("status") == "completed"

    def run(command, value)
      authorize_site!(@site, :command, risk: list.risk)
      c = Points::Command.call(list, command, value, source: "web", user: current_user)
      flash[:alert] = c.error if c.error
      redirect_to site_todo_lists_path(@site, anchor: "lista-#{list.id}")
    rescue Points::Command::Error => e
      redirect_to site_todo_lists_path(@site, anchor: "lista-#{list.id}"), alert: e.message
    end
  end
end
