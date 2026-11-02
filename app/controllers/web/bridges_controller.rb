module Web
  # Pontes de exposição do local (integ): o que cada ponte (Matter…) mostra,
  # com o nome, o pareamento (QR e código que o serviço manda) e a chave do
  # serviço. Mesmo padrão do "Expor para a Alexa". Ver: qualquer papel;
  # mudar e gerar chave: dono do local.
  class BridgesController < ApplicationController
    before_action :load

    def show
      authorize_site!(@site, :view)
      prepare
    end

    def update
      authorize_site!(@site, :admin)
      by_id = Bridges.candidates(@bridge, @site).to_h { |p, _| [ p.id, p ] }
      exposed = exposures
      errors = params.fetch(:items, {}).to_unsafe_h.filter_map do |id, f|
        point = by_id[id] or next
        e = exposed[id]
        next e&.destroy && nil unless f[:exposed] == "1"

        e ||= BridgeExposure.new(site: @site, point: point, bridge: @bridge.key)
        e.assign_attributes(name: f[:name], risk_confirmed: f[:confirm] == "1")
        next if (e.persisted? && !e.changed?) || e.save

        e.errors.full_messages.to_sentence
      end
      redirect_to site_bridge_path(@site, @bridge.key), **(errors.any? ? { alert: errors.first(3).to_sentence } : { notice: t("bridges.flash.saved") })
    end

    # Chave de integração do serviço (ler e comandar só este local). Aparece uma vez.
    def service_key
      authorize_site!(@site, :admin)
      _, @key = ServiceApiKey.issue(current_user, name: "#{t("bridges.title", name: @bridge.title)} (#{@site.name})", scopes: %w[read command], site_ids: [ @site.id ])
      flash.now[:notice] = t("bridges.flash.key_generated")
      prepare
      render :show
    end

    private

    def load
      @site = Site.find(params[:site_id])
      @bridge = Bridges[params[:key]] or raise ActiveRecord::RecordNotFound
    end

    def exposures = BridgeExposure.where(site: @site, bridge: @bridge.key).index_by(&:point_id)

    def prepare
      @items = Bridges.candidates(@bridge, @site)
      @exposed = exposures
      @status = Bridges.status(@bridge, current_user.tenant)
    end
  end
end
