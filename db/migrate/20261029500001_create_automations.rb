# F6 (ESQUEMA-V1 §4.5 e §5): automações com a DSL JSON. `definition` é a
# versão publicada (a que roda), `draft` o rascunho do editor; cada publicação
# vira uma linha em `automation_versions` (voltar versão). `automation_runs`
# guarda o trace passo a passo e o estado de quem está esperando (`state`:
# contador de programa, variáveis), para a espera sobreviver a reinício.
class CreateAutomations < ActiveRecord::Migration[8.1]
  def change
    create_table :automations, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :area, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.text :description
      t.boolean :enabled, null: false, default: false
      t.string :mode, null: false, default: "single"
      t.integer :max_runs, null: false, default: 10
      t.jsonb :definition, null: false, default: {}
      t.jsonb :draft
      t.integer :version, null: false, default: 0
      t.string :webhook_token
      t.datetime :last_run_at
      t.string :last_status
      t.string :last_error
      t.timestamps
      t.index :webhook_token, unique: true
    end

    create_table :automation_versions, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :automation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :author, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :version, null: false
      t.jsonb :definition, null: false
      t.datetime :created_at, null: false
      t.index %i[automation_id version], unique: true
    end

    create_table :automation_runs, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :automation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :cause_run, type: :uuid, foreign_key: { to_table: :automation_runs, on_delete: :nullify }
      t.integer :version
      t.jsonb :trigger, null: false, default: {}
      t.string :status, null: false, default: "running"
      t.boolean :dry_run, null: false, default: false
      t.integer :depth, null: false, default: 0
      t.jsonb :steps, null: false, default: []
      t.jsonb :state, null: false, default: {}
      t.string :error
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.datetime :resume_at
      t.timestamps
      t.index %i[automation_id created_at]
      t.index %i[site_id status]
    end

    # Comando mandado por uma execução de automação: a causa, para a proteção
    # contra laço (ESQUEMA-V1 §5).
    add_reference :commands, :automation_run, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
