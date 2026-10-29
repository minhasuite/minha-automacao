# De hora em hora: Billing::Reconcile (assinaturas vencidas sem aviso e o
# plano das empresas).
class BillingReconcileJob < ApplicationJob
  queue_as :default

  def perform = Billing::Reconcile.call
end
