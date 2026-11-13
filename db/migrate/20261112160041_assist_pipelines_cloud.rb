# voz-offline: o pipeline pode proibir a nuvem (STT, TTS e IA só da rede da casa).
class AssistPipelinesCloud < ActiveRecord::Migration[8.1]
  def change
    add_column :assist_pipelines, :cloud, :boolean, default: true, null: false
  end
end
