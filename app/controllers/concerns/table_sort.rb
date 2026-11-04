# Ordenação das tabelas (Ss::DataTableComponent): o cabeçalho manda ?sort=&dir= e o
# controller ordena a consulta (no servidor). @sort/@dir vão para o sort:/dir: do
# componente; coluna fora da lista volta para a padrão.
#
#   order = table_sort({ "name" => "users.name", "role" => "users.role" }, default: "name")
#   @people = scope.order(order)
module TableSort
  extend ActiveSupport::Concern

  private

  def table_sort(columns, default:, dir: "asc")
    chosen = params[:sort].to_s.presence_in(columns.keys)
    @sort = chosen || default
    @dir = chosen ? (params[:dir].to_s == "desc" ? "desc" : "asc") : dir
    column = Arel.sql(columns.fetch(@sort)) # só as expressões da lista do controller
    (@dir == "desc" ? column.desc : column.asc).nulls_last
  end
end
