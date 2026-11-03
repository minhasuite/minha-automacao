# ondaB2 (B11): temas criados pela pessoa (cores, papel de parede, vidro e fonte).
class OndaB2Temas < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboard_themes, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :key, null: false
      t.string :name, null: false
      t.string :accent, null: false
      t.string :accent2, null: false
      t.string :wall_style, null: false, default: "glow"
      t.boolean :glass, null: false, default: false
      t.string :font, null: false, default: "manrope"
      t.timestamps
    end
    add_index :dashboard_themes, %i[tenant_id key], unique: true
  end
end
