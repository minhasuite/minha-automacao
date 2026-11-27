# Arquivar aviso (web e app): sai da lista e do sino, fica em ?archived=true e volta
# pelo desfazer (POST /notifications/:id/unarchive).
class AddArchivedAtToNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :notifications, :archived_at, :datetime
  end
end
