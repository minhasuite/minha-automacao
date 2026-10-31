module Accounts
  # Os dados da empresa num Hash legível (LGPD): conta, empresa, membros e
  # notificações. Cada tabela do domínio que chegar entra aqui.
  class ExportData
    def self.call(tenant, user) = new(tenant, user).call

    def initialize(tenant, user)
      @tenant = tenant
      @user = user
    end

    def call
      ActsAsTenant.with_tenant(@tenant) do
        {
          exported_at: Time.current.iso8601,
          user: { name: @user.name, email: @user.email, role: @user.role, created_at: @user.created_at.iso8601 },
          company: CompanySerializer.new(@tenant).to_h,
          members: @tenant.users.order(:name).map { |u| { name: u.name, email: u.email, role: u.role, joined_at: u.created_at.iso8601 } },
          notifications: Notification.order(:created_at).map { |n| n.slice(:kind, :title, :body, :read_at, :created_at) },
          sites: SiteSerializer.new(Site.order(:name)).to_h,
          areas: AreaSerializer.new(Area.order(:name)).to_h,
          devices: DeviceSerializer.new(Device.order(:name)).to_h,
          points: PointSerializer.new(Point.order(:key)).to_h,
          # Leituras ficam de fora (volume); o histórico de comandos e eventos vai.
          commands: CommandSerializer.new(Command.includes(:point).order(:created_at)).to_h,
          events: Event.order(:at).map { |e| e.slice(:point_id, :kind, :payload, :source, :at) },
          # Automação (F4): as regras como estão no banco.
          **[ PointLink, Scene, Schedule, NotifyRule, AlertRule, Alert, Dashboard, Blueprint ].to_h do |m|
            [ m.table_name.to_sym, m.order(:created_at).map { |r| r.as_json(except: "tenant_id") } ]
          end,
          # Automações (F6): a definição publicada e o rascunho (sem o token do webhook).
          automations: Automation.order(:created_at).map { |r| r.as_json(except: %w[tenant_id webhook_token]) },
          # Dados (Lote 2): conjuntos e registros; IA: contas sem a chave e o uso.
          datasets: Dataset.order(:created_at).map { |r| r.as_json(except: "tenant_id") },
          packages: Package.order(:created_at).map { |r| r.as_json(except: "tenant_id") },
          dataset_records: DatasetRecord.order(:created_at).limit(100_000).map { |r| r.as_json(except: "tenant_id") },
          ai_accounts: AiAccount.order(:provider).map { |r| r.as_json(except: %w[tenant_id api_key]) },
          ai_calls: AiCall.order(:created_at).map { |r| r.as_json(except: "tenant_id") },
          external_refs: ExternalRef.order(:created_at).map { |r| r.as_json(except: "tenant_id") },
          shadow_reports: ShadowReport.order(:created_at).map { |r| r.as_json(except: "tenant_id") },
          # Integrações (F8): sem as credenciais.
          integrations: Integration.order(:created_at).map { |r| r.as_json(except: %w[tenant_id credentials inventory]) }
        }
      end
    end
  end
end
