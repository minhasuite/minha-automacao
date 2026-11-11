# P3 (proposta de personalização, "Fora dos painéis"): o que era código vira
# dado da casa.
# - custom_health_checks: verificação de Saúde do dono (consulta de pontos e/ou
#   expressão da calculadora, severidade e texto em Liquid).
# - alert_rules.message: texto do aviso do alerta em Liquid (o aviso por
#   mudança, notify_rules.message, já é texto livre e passa a aceitar Liquid).
# - assist_custom_intents: frase dita → cena ou script, por local e idioma.
# - assist_custom_responses: resposta da casa no lugar da padrão de uma
#   intenção, por local e idioma.
class P3PersonalizacaoDados < ActiveRecord::Migration[8.1]
  def change
    create_table :custom_health_checks, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :query
      t.string :expression
      t.string :severity, null: false, default: "warn"
      t.text :message
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :custom_health_checks, :tenant_id

    add_column :alert_rules, :message, :text

    create_table :assist_custom_intents, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :scene, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.references :point, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.string :language
      t.string :sentences, array: true, null: false, default: []
      t.string :response
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :assist_custom_intents, :tenant_id

    create_table :assist_custom_responses, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :language
      t.string :intent, null: false
      t.string :text_key, null: false
      t.string :text, null: false
      t.timestamps
    end
    add_index :assist_custom_responses, :tenant_id
    add_index :assist_custom_responses, %i[site_id intent text_key language], unique: true, nulls_not_distinct: true, name: "index_assist_custom_responses_unique"
  end
end
