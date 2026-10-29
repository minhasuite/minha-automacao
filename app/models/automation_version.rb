# Cada publicação de uma automação (voltar versão, G5).
class AutomationVersion < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :automation
  belongs_to :author, class_name: "User", optional: true
end
