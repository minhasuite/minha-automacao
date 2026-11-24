# Amostra de uma instalação do integrador (a cada resumo): temperatura, CPU, memória, disco e internet, para os
# gráficos da central. Sem chave primária (como `readings`): sempre `order(:at)`; apagada depois de 30 dias.
class InstallationSample < ApplicationRecord
  self.primary_key = nil

  belongs_to :installation

  def self.prune!(now = Time.current) = where(at: ...now - Installation::SAMPLE_KEEP).delete_all
end
