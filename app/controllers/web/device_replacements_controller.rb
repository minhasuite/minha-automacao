module Web
  # "Substituir aparelho" (técnico+): escolhe o aparelho novo do mesmo local,
  # mapeia ponto antigo → ponto novo (sugestão de `Devices::Replace`), mostra a
  # prévia e aplica; "desfazer" devolve os pontos. Regra toda no serviço.
  class DeviceReplacementsController < ApplicationController
    def show
      load_device
      @candidates = Devices::Replace.candidates(@device)
      @new_device = @candidates.find_by(id: params[:por]) if params[:por].present?
      @pairs = Devices::Replace.suggest(@device, @new_device) if @new_device
      @news = Devices::Replace.points_of(@new_device) if @new_device
      @retire = "remove"
      @take_name = @assistant.present?
    end

    def create
      load_device
      @new_device = Devices::Replace.candidates(@device).find(params[:new_device_id])
      @retire = params[:retire].presence_in(Devices::Replace::RETIRE) || "remove"
      @take_name = params[:take_name] == "1"
      pairs = Devices::Replace.pairs_from(@device, @new_device, params.permit(map: {}, invert: {}).to_h)
      if params[:preview].present?
        @preview = Devices::Replace.preview(@device, @new_device, pairs, retire: @retire)
        return render(:preview)
      end

      Devices::Replace.call(@device, @new_device, pairs, user: current_user, retire: @retire, take_name: @take_name)
      back = @assistant ? site_pairing_path(@site, @assistant) : device_path(@new_device)
      redirect_to back, notice: t("devices.replace.done", count: pairs.size), status: :see_other
    rescue Devices::Replace::Error => e
      redirect_to replace_device_path(@device, por: @new_device&.id, assistente: @assistant), alert: e.message, status: :see_other
    end

    def undo
      load_device
      event = Devices::Replace.last_event(@device) or return redirect_to(device_path(@device), alert: t("devices.replace.errors.undone"), status: :see_other)
      Devices::Replace.undo!(event, user: current_user)
      redirect_to device_path(@device), notice: t("devices.replace.undone"), status: :see_other
    rescue Devices::Replace::Error => e
      redirect_to device_path(@device), alert: e.message, status: :see_other
    end

    private

    def load_device
      @device = Device.find(params[:id])
      @site = @device.site
      authorize_site!(@site, :manage)
      # Veio do assistente de pareamento: volta para ele e sugere ficar com o nome antigo.
      @assistant = Pairing.adapter(params[:assistente])&.key
    end
  end
end
