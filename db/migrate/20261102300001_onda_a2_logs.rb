# ondaA2 (A12): log do sistema resumido (o "Logs" do HA): avisos e erros do
# servidor agrupados por mensagem, com contagem, primeira e última vez.
class OndaA2Logs < ActiveRecord::Migration[8.1]
  def change
    create_table :system_logs, id: :uuid do |t|
      t.string :level, null: false
      t.string :source, null: false
      t.text :message, null: false
      t.string :digest, null: false, index: { unique: true }
      t.integer :count, null: false, default: 1
      t.datetime :first_at, null: false
      t.datetime :last_at, null: false, index: true
    end
  end
end
