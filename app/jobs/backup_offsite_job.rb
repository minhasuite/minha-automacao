# Cópia fora de casa (G20): de hora em hora manda o dump novo, se houver
# (`Backups.offsite!`); no domingo, o teste de restauração (`"restore"`).
# Erro fica no estado do backup (tela de saúde e ponto do Sistema), não na fila.
class BackupOffsiteJob < ApplicationJob
  include SlowJob

  def perform(step = "upload")
    step == "restore" ? Backups.restore_test! : Backups.offsite!
  end
end
