# F9: Alexa Smart Home. O vínculo da skill (account linking) é um ApiToken
# de `client: "alexa"` preso a um local; o código de autorização é o mesmo
# registro antes do primeiro uso (`redirect_uri` guardado para a troca).
# Exposição por ponto e por cena, desligada por padrão.
class F9AlexaSmartHome < ActiveRecord::Migration[8.1]
  def change
    add_reference :api_tokens, :site, type: :uuid, foreign_key: { on_delete: :cascade }
    add_column :api_tokens, :client, :string
    add_column :api_tokens, :redirect_uri, :string
    add_index :api_tokens, :client

    add_column :points, :alexa_exposed, :boolean, null: false, default: false
    add_column :points, :alexa_name, :string
    add_column :scenes, :alexa_exposed, :boolean, null: false, default: false
    add_column :scenes, :alexa_name, :string
  end
end
