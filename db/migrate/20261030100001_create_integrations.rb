# F8: integrações de conta (ESQUEMA-V1 §4.2). A primeira é a Alexa: os
# cookies da sessão valem para todas as Echo. O robô Xiaomi fala direto pela
# rede local com o token do próprio aparelho (`devices.credential`), então
# não precisa de conta.
class CreateIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :integrations, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :driver, null: false
      t.string :name, null: false
      t.jsonb :settings, null: false, default: {}
      t.text :credentials
      t.string :status, null: false, default: "pending"
      t.string :last_error
      t.datetime :last_ok_at
      t.timestamps
    end
    add_reference :devices, :integration, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
