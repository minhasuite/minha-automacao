# Cada publicação de um dashboard (voltar versão, G5).
class DashboardVersion < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :dashboard
  belongs_to :author, class_name: "User", optional: true
end
