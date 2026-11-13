module Api
  module V1
    # "Substituir aparelho" (técnico+), o mesmo serviço da web (`Devices::Replace`):
    # GET  /devices/:id/replace?new_device_id=   → aparelhos possíveis e pares sugeridos
    # POST /devices/:id/replace                  → {new_device_id, pairs: [{old, new, invert}] | map, retire, take_name, preview}
    # POST /devices/:id/replace/undo             → desfaz a última substituição
    class DeviceReplacementsController < BaseController
      def show
        device = load_device
        candidates = Devices::Replace.candidates(device)
        body = { candidates: candidates.map { |d| { id: d.id, name: d.name, driver: d.driver } } }
        if params[:new_device_id].present?
          new_device = candidates.find(params[:new_device_id])
          body[:pairs] = Devices::Replace.suggest(device, new_device).map { |p| pair_json(p.old, p.new, p.invert) }
          body[:new_points] = Devices::Replace.points_of(new_device).map { |p| point_json(p) }
        end
        render_data(body)
      end

      def create
        device = load_device
        new_device = Devices::Replace.candidates(device).find(params.require(:new_device_id))
        retire = params[:retire].presence_in(Devices::Replace::RETIRE) || "remove"
        raw = params.permit(map: {}, invert: [], pairs: %i[old new invert]).to_h
        pairs = Devices::Replace.pairs_from(device, new_device, raw)
        if ActiveModel::Type::Boolean.new.cast(params[:preview])
          pv = Devices::Replace.preview(device, new_device, pairs, retire: retire)
          return render_data({ pairs: pv[:pairs].map { |r| pair_json(r[:old], r[:new], r[:invert]).merge(usages: r[:usages], new_point_usages: r[:new_usages]) },
                               old_points_left: pv[:old_left].map { |p| point_json(p) }, new_points_left: pv[:new_left].map { |p| point_json(p) }, retire: pv[:retire] })
        end

        event = Devices::Replace.call(device, new_device, pairs, user: current_user, retire: retire, take_name: ActiveModel::Type::Boolean.new.cast(params[:take_name]) == true)
        render_data({ audit_event_id: event.id, retire: event.details["retire"], pairs: event.details["pairs"].map { |e| e.slice("old_point_id", "new_point_id", "invert") } })
      rescue Devices::Replace::Error => e
        render_error(:replace_failed, e.message, status: :unprocessable_content)
      end

      def undo
        device = load_device
        event = Devices::Replace.last_event(device) or return render_error(:replace_failed, I18n.t("devices.replace.errors.undone"), status: :unprocessable_content)
        Devices::Replace.undo!(event, user: current_user)
        render_data({ undone: event.id })
      rescue Devices::Replace::Error => e
        render_error(:replace_failed, e.message, status: :unprocessable_content)
      end

      private

      def load_device
        device = Device.find(params[:id])
        authorize_site!(device.site, :manage)
        device
      end

      def point_json(p) = { id: p.id, key: p.key, name: p.name, capability: p.capability, unit: p.unit, device_class: p.device_class }
      def pair_json(old_point, new_point, invert) = { old: point_json(old_point), new: new_point && point_json(new_point), invert: invert ? true : false }
    end
  end
end
