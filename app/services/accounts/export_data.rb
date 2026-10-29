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
          events: Event.order(:at).map { |e| e.slice(:point_id, :kind, :payload, :source, :at) }
        }
      end
    end
  end
end
