# Diário: links dos chips de período e o filtro da Ss::FilterBarComponent, sem o cursor da página.
module LogbookHelper
  # Período: troca o período e tira as datas escolhidas.
  def lb_period_path(filter, period) = logbook_path(filter.to_params.except(:from, :until, :before).merge(site_id: filter.site.id, period: period))

  # Filtro atual para o Ss::FilterBarComponent (o site_id vai na query do url:).
  def lb_bar_params(filter) = filter.to_params.except(:before, :site_id).deep_stringify_keys

  # "+ Filtro" do Diário: tipos (vários, sources[]; nenhum = todos), área, aparelho e pessoa; o
  # ponto só quando já escolhido (vem da página do ponto), para o chip ter o nome.
  def lb_bar_filters(filter, site, sources)
    [ { param: :sources, label: t("logbook.what"), multiple: true, options: sources.map { |s| [ s.label, s.key ] } },
      { param: :area_id, label: t("devices.area"), options: site.areas.order(:name).map { |a| [ a.name, a.id ] } },
      { param: :device_id, label: t("logbook.device"), options: site.devices.order(:name).map { |d| [ d.name, d.id ] } },
      ({ param: :point_id, label: t("logbook.point"), options: site.points.includes(:device).where(id: filter.point_id).map { |p| [ "#{p.name} · #{p.device.name}", p.id ] } } if filter.point_id),
      { param: :user_id, label: t("logbook.person"), options: Logbook.people(site).map { |u| [ u.name, u.id ] } } ].compact
  end

  # Fim do registro: o próximo período maior (7 dias → 30 → 1 ano); nada com datas próprias.
  def lb_bigger_path(filter)
    return if filter.custom_dates?

    keys = Logbook::PERIODS.keys
    bigger = keys[keys.index(filter.period).to_i + 1] or return
    lb_period_path(filter, bigger)
  end
end
