module Companies
  # Entrar noutra empresa com o código do convite. A empresa ATUAL da pessoa: se
  # ela é o único membro e já tem dados, exige `discard_current` (é dado que
  # some); se sobra gente, ela só sai.
  class Join
    class Error < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def self.call(user:, code:, discard_current: false) = new(user, code, discard_current).call

    def initialize(user, code, discard_current)
      @user = user
      @code = code
      @discard = discard_current
    end

    def call
      invite = Invite.find_valid(@code) or raise Error.new(:invalid_invite, "Código inválido ou vencido.")
      old = @user.tenant
      raise Error.new(:already_member, "Você já faz parte desta empresa.") if invite.tenant_id == old.id

      alone = old.users.where.not(id: @user.id).none?
      if alone && has_data?(old) && !@discard
        raise Error.new(:company_not_empty, "Sua empresa atual tem dados. Exporte ou confirme que podem ser apagados.")
      end

      ActiveRecord::Base.transaction do
        ActsAsTenant.without_tenant { invite.update!(accepted_at: Time.current, accepted_by: @user) }
        @user.update!(tenant_id: invite.tenant_id, role: invite.role)
        Accounts::DestroyCompany.call(old) if alone
      end
      @user.reload.tenant
    end

    private

    def has_data?(tenant)
      ActsAsTenant.with_tenant(tenant) { Accounts::WipeData::MODELS.any?(&:exists?) }
    end
  end
end
