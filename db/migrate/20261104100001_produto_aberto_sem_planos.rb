# Produto aberto (04/11/2026): sem planos, licença, assinatura pela Play nem IA
# paga da suíte. A IA continua só com a chave da instalação (AiAccount/AiCall).
class ProdutoAbertoSemPlanos < ActiveRecord::Migration[8.1]
  def up
    drop_table :subscriptions, if_exists: true
    drop_table :ai_plan_features, if_exists: true
    drop_table :ai_tier_configs, if_exists: true
    drop_table :ai_usages, if_exists: true
    remove_column :tenants, :plan, if_exists: true
    remove_column :tenants, :plan_provider, if_exists: true
    remove_column :tenants, :plan_expires_at, if_exists: true
    execute "DELETE FROM feature_flags WHERE key = 'ai'"
    execute "UPDATE tenants SET settings = settings - 'license' WHERE settings ? 'license'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
