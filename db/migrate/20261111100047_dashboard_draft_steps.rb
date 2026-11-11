# Ideia 5 (desfazer/refazer no editor de painel): cada gravação do rascunho
# guarda o rascunho de antes (`undo`); desfazer o traz de volta e guarda o
# atual em `redo`. `definition` nulo = "sem rascunho" (a versão publicada).
# Publicar zera a pilha. Até `Dashboards::History::MAX` passos por painel.
class DashboardDraftSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboard_draft_steps, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :dashboard, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :author, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :kind, null: false
      t.string :label
      t.jsonb :definition
      t.datetime :created_at, null: false
      t.index %i[dashboard_id kind created_at]
    end
  end
end
