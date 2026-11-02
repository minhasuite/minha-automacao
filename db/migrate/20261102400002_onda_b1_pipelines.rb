# ondaB1 (B5): pipelines do Assist (idioma, agente, STT, TTS e palavra de
# ativação por motor plugável) e o histórico de execuções para a depuração.
class OndaB1Pipelines < ActiveRecord::Migration[8.1]
  def change
    create_table :assist_pipelines, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :language, null: false, default: "pt-BR"
      t.string :agent, null: false, default: "local"
      t.string :llm_provider
      t.jsonb :stt, null: false, default: {}
      t.jsonb :tts, null: false, default: {}
      t.jsonb :wake, null: false, default: {}
      t.boolean :preferred, null: false, default: false
      t.timestamps
    end
    add_index :assist_pipelines, :tenant_id

    create_table :assist_runs, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :pipeline, type: :uuid, foreign_key: { to_table: :assist_pipelines, on_delete: :nullify }, index: false
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      t.uuid :satellite_id
      t.string :source, null: false
      t.string :language
      t.string :heard
      t.string :intent
      t.text :reply
      t.jsonb :stages, null: false, default: []
      t.string :error
      t.integer :duration_ms
      t.datetime :created_at, null: false
    end
    add_index :assist_runs, %i[site_id created_at], order: { created_at: :desc }
    add_index :assist_runs, :tenant_id
  end
end
