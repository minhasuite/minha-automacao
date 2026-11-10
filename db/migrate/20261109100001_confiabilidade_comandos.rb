# Confiabilidade (docs/confiabilidade.md): tentativas do comando (nova
# tentativa automática em falha passageira) e o lote de um anúncio único em
# várias Echo da mesma conta (o comando que executa é o líder: batch_id = id).
class ConfiabilidadeComandos < ActiveRecord::Migration[8.1]
  def change
    add_column :commands, :attempts, :integer, default: 0, null: false
    add_column :commands, :batch_id, :uuid
    add_index :commands, :batch_id, where: "batch_id IS NOT NULL"
    # Saúde: falhas recentes por ponto e pico de falhas (status + data).
    add_index :commands, [ :status, :created_at ], where: "status = 'failed'", name: "index_commands_failed_recent"
    add_index :automation_runs, [ :status, :updated_at ], where: "status IN ('running', 'waiting', 'queued')", name: "index_automation_runs_open"
  end
end
