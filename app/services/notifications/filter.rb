module Notifications
  # Filtros da central (web e API): tipo (`kind`), área (pelo ponto do aviso),
  # nível e só não lidas. As opções vêm do que existe, com rótulo no idioma da tela.
  module Filter
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def apply(scope, params)
      kind = params[:kind].to_s.presence_in(Notification::KINDS)
      area = params[:area_id].to_s[UUID]
      level = params[:level].to_s.presence_in(LEVELS)
      scope = scope.where(kind: kind) if kind
      scope = scope.where("notifications.data->>'point_id' IN (?)", Point.where(area_id: area).select("points.id::text")) if area
      if level
        scope = level == "normal" ? scope.where("COALESCE(notifications.data->>'priority', 'normal') NOT IN ('high', 'critical')") : scope.where("notifications.data->>'priority' = ?", level)
      end
      scope = scope.unread if ActiveModel::Type::Boolean.new.cast(params[:unread])
      scope
    end

    def active(params) = params.to_h.symbolize_keys.slice(:kind, :area_id, :level, :unread).compact_blank

    def kind_label(kind) = I18n.t("notifications.kinds.#{kind}", default: kind.to_s.humanize)
    def level_label(level) = I18n.t("notifications.level.#{level}")

    # {kinds: [[valor, rótulo]], areas: [[id, "Local · Área"]], levels: [...]}
    def choices(user)
      kinds = Notification.for_user(user).distinct.pluck(:kind)
      sites = Site.order(:name).select { |s| s.role_for(user) }
      areas = Area.where(site_id: sites.map(&:id)).includes(:site).order(:name).map { |a| [ a.id, sites.size > 1 ? "#{a.site.name} · #{a.name}" : a.name ] }
      { kinds: (Notification::KINDS & kinds).map { |k| [ k, kind_label(k) ] }, areas: areas, levels: LEVELS.map { |l| [ l, level_label(l) ] } }
    end
  end
end
