# Diário: links dos chips de filtro (faixa .ss-chipbar da gem). Cada chip é um link com o
# mesmo filtro e uma mudança, sem o cursor da página.
module LogbookHelper
  # Período: troca o período e tira as datas escolhidas.
  def lb_period_path(filter, period) = logbook_path(filter.to_params.except(:from, :until, :before).merge(site_id: filter.site.id, period: period))

  # Tipo (fonte): liga ou desliga um tipo. Nenhum marcado = todos (sem o parâmetro).
  def lb_source_path(filter, key, all)
    on = lb_source_on?(filter, key, all)
    keys = (filter.keys.size < all.size ? filter.keys : [])
    keys = on ? keys - [ key ] : keys + [ key ]
    keys = [] if keys.size >= all.size
    logbook_path(filter.to_params.except(:sources, :before).merge(site_id: filter.site.id, sources: keys.presence))
  end

  def lb_source_on?(filter, key, all) = filter.keys.size < all.size && filter.keys.include?(key)

  # Fim do registro: o próximo período maior (7 dias → 30 → 1 ano); nada com datas próprias.
  def lb_bigger_path(filter)
    return if filter.custom_dates?

    keys = Logbook::PERIODS.keys
    bigger = keys[keys.index(filter.period).to_i + 1] or return
    lb_period_path(filter, bigger)
  end
end
