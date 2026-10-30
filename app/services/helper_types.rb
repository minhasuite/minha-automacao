# Helpers (F8e), como os do HA, abertos para extensão: cada tipo é um plugin
# (`HelperTypes::Plugin`, um arquivo em app/services/helper_types/)
# registrado em `PLUGINS`, com a partial de formulário
# `web/site_helpers/forms/_<key>`. Nada de `case` por tipo fora do plugin.
#
# Um helper é um ponto (`points.helper` = chave do tipo, configuração em
# `points.address`) do dispositivo virtual "Helpers" do local. Por ser ponto,
# automações, painéis, histórico, espelhamento e API funcionam sem código
# novo. Comando: `Points::Command` pergunta ao plugin (`commands`,
# `new_value`) e o driver virtual entrega a ele (`execute`).
module HelperTypes
  # Ordem = ordem do catálogo. Tipo novo: classe + uma linha aqui + partial.
  PLUGINS = %w[Toggle Number Select Text Datetime Button Counter Timer Group Template Statistics].freeze
  # `external_id` do dispositivo virtual que guarda os helpers do local.
  DEVICE_ID = "helpers".freeze
  # Ícones que o formulário oferece (arquivos de app/assets/images/icons).
  ICONS = Dir[Rails.root.join("app/assets/images/icons/*.svg")].map { |f| File.basename(f, ".svg") }.sort.freeze

  module_function

  def plugins = PLUGINS.map { |name| const_get(name) }
  def plugin(key) = plugins.find { |p| p.key == key.to_s }
  def keys = plugins.map(&:key)
  def for(point) = point&.helper && plugin(point.helper)

  def device(site) = site.devices.find_or_create_by!(driver: "virtual", external_id: DEVICE_ID) { |d| d.name = "Helpers" }

  # Ponto novo do tipo, ainda sem salvar.
  def build(site, plugin) = device(site).points.new(site: site, helper: plugin.key, capability: plugin.capability, history: "on_change", address: { "restore" => true })

  # Formulário → ponto (comum + o do tipo). → true se salvou.
  def save(point, form)
    plugin = self.for(point)
    form = form.to_h.stringify_keys
    point.assign_attributes(form.slice("name", "icon", "area_id").transform_values(&:presence))
    point.icon = nil unless point.icon.nil? || ICONS.include?(point.icon)
    point.address = point.address.merge("restore" => form.key?("restore") ? ActiveModel::Type::Boolean.new.cast(form["restore"]) : point.address.fetch("restore", true))
    plugin.assign(point, form)
    point.key = Integrations.unique_key(point.site, point.device, point.name) if point.new_record? && point.key.blank? && point.name.present?
    fresh = point.new_record?
    return false if point.errors.any? || !point.save

    plugin.refresh!(point) if plugin.sourced?
    point.report!(plugin.initial_value(point)) if fresh && !plugin.sourced?
    true
  end

  # Valor de um ponto mudou: refaz os helpers que dependem dele (grupo, sensor calculado, estatística).
  def on_change(point)
    dependents(point.site_id, [ point.id ]).find_each { |h| self.for(h)&.refresh!(h) }
  end

  def dependents(site_id, ids)
    Point.where(site_id: site_id).where.not(helper: nil).where("jsonb_exists_any(points.address->'sources', ARRAY[?]::text[])", ids)
  end

  # No começo do worker: quem não restaura volta ao valor inicial.
  def boot!
    ActsAsTenant.without_tenant do
      Point.where.not(helper: nil).where("points.address->>'restore' = 'false'").find_each do |p|
        ActsAsTenant.with_tenant(p.tenant) { (plugin = self.for(p)) && !plugin.sourced? && plugin.reset!(p) }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end
    end
  end
end
