module Onboarding
  module Steps
    # Procura na rede com todos os plugins que sabem descobrir (mDNS, SSDP e os
    # próprios) de uma vez; a pessoa marca o que quer e cada plugin adiciona
    # (`add_found`). O que precisa de conta ou chave fica para Integrações.
    class DiscoverStep < Step
      describe key: "discover", icon: "search", art: "radar"

      def self.save(ctx, params)
        added = Array(params[:pick]).count do |raw|
          entry = JSON.parse(raw.to_s)
          plugin = Integrations.plugin(entry["plugin"])
          plugin&.add_found(ctx.site, entry.except("plugin")).present?
        rescue JSON::ParserError, ActiveRecord::RecordInvalid
          false
        end
        ctx.notice = I18n.t("onboarding.discover.added", count: added) if added.positive?
        nil
      end
    end
  end
end
