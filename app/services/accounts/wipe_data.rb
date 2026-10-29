module Accounts
  # "Zerar dados": apaga o CONTEÚDO da empresa e deixa em pé a empresa, os
  # membros, o login e o plano. AiUsage fica (senão zerar resetaria a cota).
  # Cada tabela do domínio que chegar entra em MODELS (filhos antes dos pais).
  class WipeData
    MODELS = [ AutomationRun, AutomationVersion, Automation, DashboardVersion, Dashboard, Alert, AlertRule, NotifyRule, Schedule, Scene, PointLink, Command, Event, Tagging, Tag, SiteMembership, Point, Device, Integration, Area, Site, Notification ].freeze

    def self.call(tenant) = new(tenant).call

    def initialize(tenant)
      @tenant = tenant
    end

    def call
      ActsAsTenant.with_tenant(@tenant) do
        ActiveRecord::Base.transaction do
          counts = MODELS.to_h { |m| [ m.table_name, m.count ] }
          MODELS.each(&:delete_all)
          counts
        end
      end
    end
  end
end
