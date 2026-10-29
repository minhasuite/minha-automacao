module Billing
  # Aplica o estado que a Play reporta para um comprovante. Chamado pela
  # verificação (o app acabou de comprar ou restaurou), pelo RTDN e pela
  # reconciliação — todos idempotentes (o app reenvia; o Pub/Sub reentrega).
  class PlaySync
    class Error < StandardError; end

    def self.call(purchase_token, user: nil) = new(purchase_token, user).call

    def initialize(purchase_token, user)
      @token = purchase_token
      @user = user
    end

    def call
      existing = Subscription.find_by(source: "play", external_id: @token)
      data = GooglePlay.subscription(@token)
      owner = @user || existing&.user || account_user(data)
      tenant = existing&.tenant || owner&.tenant
      # RTDN de comprovante que ninguém verificou e sem conta reconhecível:
      # ignorar é melhor que adivinhar.
      return nil if tenant.nil?

      guard_owner!(existing, owner)
      guard_account!(data, owner)
      sub = save(existing, data, owner, tenant)
      replace_linked!(data[:linked_token], tenant)
      Entitlement.recompute!(tenant)
      sub
    end

    private

    def save(existing, data, owner, tenant)
      sub = existing || Subscription.new(source: "play", external_id: @token, tenant: tenant, user: owner)
      sub.update!(product_id: data[:product_id], base_plan_id: data[:base_plan_id], offer_id: data[:offer_id],
                  plan: data[:plan] || (sub.plan.presence || Plans::DEFAULT), status: data[:status], trial: data[:trial],
                  auto_renewing: data[:auto_renewing], expires_at: data[:expires_at], linked_external_id: data[:linked_token],
                  verified_at: Time.current)
      sub
    rescue ActiveRecord::RecordNotUnique
      # Verificação e RTDN chegaram juntos: o outro criou; aplica por cima.
      existing = Subscription.find_by!(source: "play", external_id: @token)
      retry
    end

    # Upgrade/downgrade: o comprovante novo aponta o antigo, que deixa de valer.
    def replace_linked!(linked, tenant)
      return if linked.blank?

      Subscription.where(source: "play", external_id: linked, tenant: tenant).update_all(status: "replaced", updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # A compra leva o id do usuário (obfuscatedExternalAccountId).
    def account_user(data) = data[:account_id] && User.find_by(id: data[:account_id])

    # O comprovante é o segredo: preso a outra CASA, aceitar de novo seria
    # transferir assinatura com um copiar e colar.
    def guard_owner!(existing, owner)
      return if existing.nil? || owner.nil? || existing.tenant_id == owner.tenant_id

      raise Error, "comprovante já vinculado a outra empresa"
    end

    def guard_account!(data, owner)
      return if data[:account_id].blank? || owner.nil? || data[:account_id] == owner.id.to_s

      raise Error, "comprovante pertence a outra conta"
    end
  end
end
