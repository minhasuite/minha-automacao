module Web
  # Assistente de pareamento (técnico+; docs/integracoes.md, "Zigbee"): abre e
  # renova o pareamento na ponte do protocolo, mostra ao vivo quem entra (o
  # quadro `ao-vivo` se recarrega a cada 2 s) e, por aparelho, a decisão: é
  # novo (nome e área, o nome vai para a ponte) ou substitui um existente
  # (sugestão do `Pairing::Suggest` → tela do "Substituir aparelho"). Regra
  # toda em `Pairing` e no adaptador do plugin.
  class PairingsController < ApplicationController
    before_action :load_adapter

    def show
      @bridge = @adapter.bridge(@site)
      @routers = @adapter.routers(@site)
      @joins = joins.recent.includes(:device)
    end

    def live
      @bridge = @adapter.bridge(@site)
      @joins = joins.recent.includes(:device)
      render layout: false
    end

    def open
      @adapter.open!(@site, params[:segundos].presence || @adapter.max_seconds, via: params[:via])
      redirect_to site_pairing_path(@site, @adapter.key), notice: t("pairing.opened"), status: :see_other
    rescue Drivers::Mqtt::Error => e
      redirect_to site_pairing_path(@site, @adapter.key), alert: e.message, status: :see_other
    end

    def close
      @adapter.close!(@site)
      redirect_to site_pairing_path(@site, @adapter.key), notice: t("pairing.closed"), status: :see_other
    rescue Drivers::Mqtt::Error => e
      redirect_to site_pairing_path(@site, @adapter.key), alert: e.message, status: :see_other
    end

    def join
      @join = joins.find(params[:join_id])
      @device = @join.device
      @suggestions = @device && !@join.resolved? ? Pairing::Suggest.call(@device) : []
      @areas = @site.areas.order(:name)
    end

    # "É novo": nome e área; o nome chega ao z2m pelo Device (Pairing.renamed).
    def create_new
      @join = joins.find(params[:join_id])
      @device = @join.device or return redirect_to(site_pairing_join_path(@site, @adapter.key, @join), alert: t("pairing.not_ready"), status: :see_other)
      @device.assign_attributes(name: params[:name].to_s.squish.presence || @device.name, area_id: @site.areas.find_by(id: params[:area_id])&.id)
      if @device.save
        @join.resolve!("new")
        redirect_to site_pairing_path(@site, @adapter.key), notice: t("pairing.saved_new", name: @device.name), status: :see_other
      else
        @suggestions = Pairing::Suggest.call(@device.reload)
        @areas = @site.areas.order(:name)
        flash.now[:alert] = @device.errors.full_messages.to_sentence
        render :join, status: :unprocessable_content
      end
    end

    def dismiss
      joins.find(params[:join_id]).resolve!("dismissed")
      redirect_to site_pairing_path(@site, @adapter.key), status: :see_other
    end

    private

    def joins = PairingJoin.where(site: @site, protocol: @adapter.key)

    def load_adapter
      @site = Site.find(params[:site_id])
      authorize_site!(@site, :manage)
      @adapter = Pairing.adapter(params[:protocolo]) or raise ActiveRecord::RecordNotFound
    end
  end
end
