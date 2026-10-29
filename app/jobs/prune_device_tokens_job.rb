# Token sem uso há 60 dias: o aparelho trocou ou desinstalou.
class PruneDeviceTokensJob < ApplicationJob
  queue_as :default

  def perform
    DeviceToken.where("COALESCE(last_seen_at, updated_at) < ?", 60.days.ago).delete_all
  end
end
