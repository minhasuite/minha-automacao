# ondaA2 (A16): verificação em duas etapas (app autenticador e códigos de
# recuperação) e passkeys (WebAuthn).
class OndaA2Mfa < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.text :otp_secret
      t.datetime :otp_enabled_at
      t.bigint :otp_last_step
      t.jsonb :otp_recovery, null: false, default: []
    end

    create_table :passkeys, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :credential_id, null: false, index: { unique: true }
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.datetime :last_used_at
      t.timestamps
    end
  end
end
