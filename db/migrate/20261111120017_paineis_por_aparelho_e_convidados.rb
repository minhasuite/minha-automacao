# Experiência do dia a dia (ideias 10 e 11 da proposta de personalização):
#
# - `panel_devices`: o aparelho que abre um painel (o tablet da parede). `key`
#   = "web:<id do cookie>" ou "app:<install_id do app>"; `dashboard_id` + `view`
#   = "neste aparelho abre o painel X" (vale por cima do padrão da pessoa).
# - `guest_links`: link temporário de convidado/babá para um painel, com papel
#   `viewer` ou `guest` no local (só os widgets marcados com `guest: true`),
#   validade, revogação e uso. Token só em digest.
class PaineisPorAparelhoEConvidados < ActiveRecord::Migration[8.1]
  def change
    create_table :panel_devices, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :key, null: false
      t.string :kind, null: false, default: "web"
      t.string :name, null: false
      t.references :dashboard, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :view
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :user_agent
      t.datetime :last_seen_at
      t.timestamps
      t.index %i[tenant_id key], unique: true
    end

    create_table :guest_links, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :site, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :dashboard, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :name, null: false
      t.string :role, null: false, default: "viewer"
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.integer :uses, null: false, default: 0
      t.timestamps
      t.index :token_digest, unique: true
    end
  end
end
