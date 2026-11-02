# ondaA1 (A5): último resultado dos gatilhos que valem enquanto algo é
# verdade (template), por índice do gatilho, para disparar só na virada.
class OndaA1Gatilhos < ActiveRecord::Migration[8.1]
  def change
    add_column :automations, :trigger_state, :jsonb, null: false, default: {}
  end
end
