# O dp `add_ele` do Tuya manda o acréscimo desde o último envio, não o total:
# o ponto passa a somar o que o aparelho empurra (`accumulate`) e a ignorar a
# leitura de estado, que repete o último acréscimo (`push_only`).
class TuyaEnergiaAcumulada < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE points SET address = address || '{"accumulate": true, "push_only": true}'::jsonb
      WHERE address->>'code' = 'add_ele'
    SQL
  end

  def down
    execute "UPDATE points SET address = address - 'accumulate' - 'push_only' WHERE address->>'code' = 'add_ele'"
  end
end
