# Fila e jobs: a latência dos comandos (última hora / 24 h) e a lista dos
# últimos comandos filtram por data. Sem este índice o Postgres lia a tabela
# inteira (o tenant_id sozinho não separa nada numa instalação só).
class CommandsPorData < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :commands, %i[tenant_id created_at], algorithm: :concurrently, if_not_exists: true
  end
end
