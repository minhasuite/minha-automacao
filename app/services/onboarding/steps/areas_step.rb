module Onboarding
  module Steps
    # Áreas sugeridas (marcar e criar) e o quadro para arrastar cada aparelho
    # para a sua área (a caixa de seleção do cartão faz o mesmo pelo teclado).
    class AreasStep < Step
      describe key: "areas", icon: "view-boards", art: "rooms"

      # chave do texto → tipo da área
      SUGGESTED = { "living" => "room", "kitchen" => "room", "bedroom" => "room", "bathroom" => "room",
                    "office" => "room", "balcony" => "room", "garage" => "room", "outdoor" => "outdoor" }.freeze

      def self.locals(ctx)
        areas = ctx.site.areas.order(:position, :name).to_a
        { areas: areas, devices: ctx.site.devices.listed.order(:name).to_a,
          suggested: SUGGESTED.keys.reject { |k| areas.any? { |a| a.name.casecmp?(I18n.t("onboarding.areas.suggested.#{k}")) } } }
      end

      def self.save(ctx, params)
        ids = ctx.site.areas.pluck(:id).to_set
        params.fetch(:device_area, {}).to_unsafe_h.each do |device_id, area_id|
          ctx.site.devices.find_by(id: device_id)&.update!(area_id: ids.include?(area_id) ? area_id : nil)
        end
        return nil if params[:create].blank?

        names = Array(params[:suggested]).filter_map { |k| [ I18n.t("onboarding.areas.suggested.#{k}"), SUGGESTED[k] ] if SUGGESTED.key?(k) } +
                params[:custom].to_s.split(",").map { |n| [ n.squish, "room" ] }
        created = names.reject { |n, _| n.blank? }.uniq(&:first).count do |name, kind|
          ctx.site.areas.find_or_create_by!(name: name) { |a| a.kind = kind }.previously_new_record?
        end
        ctx.notice = I18n.t("onboarding.areas.created", count: created)
        :stay
      end
    end
  end
end
