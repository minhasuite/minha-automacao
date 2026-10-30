# Lote 1 da paridade com o HA: Web Push (PWA) como transporte do canal
# "push" e aviso com botões (a resposta fica na própria notificação).
class Lote1PushEAvisos < ActiveRecord::Migration[8.1]
  def change
    create_table :push_subscriptions, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.text :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false
      t.string :name
      t.string :user_agent
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :push_subscriptions, :endpoint, unique: true

    add_column :notifications, :responded_at, :datetime
    add_column :notifications, :response, :jsonb
  end
end
