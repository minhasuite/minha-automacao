# Notificações com menos ruído: nível do aviso (normal/high/critical) e
# janela para juntar avisos seguidos do mesmo ponto (nil = a da instalação, 0 = não junta).
class AvisoNivelEAgrupamento < ActiveRecord::Migration[8.1]
  def change
    add_column :notify_rules, :priority, :string, default: "normal", null: false
    add_column :notify_rules, :merge_s, :integer
  end
end
