# F8c: integração de conta varre os aparelhos sozinha. `inventory` (cifrado:
# leva local_key/token) = última lista da conta; o aparelho que sumiu dela
# fica com `removed_at` (nada é apagado) e `last_error` guarda a última falha
# de leitura para o diagnóstico.
class AddIntegrationSync < ActiveRecord::Migration[8.1]
  def change
    add_column :integrations, :inventory, :text
    add_column :devices, :removed_at, :datetime
    add_column :devices, :last_error, :string
  end
end
