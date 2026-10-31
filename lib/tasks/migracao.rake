# Migração em sombra (F10, docs/migracao.md). Os arquivos do sistema de
# origem ficam numa pasta temporária (nunca no repo) e são apagados depois.
namespace :migracao do
  HA_FILES = { "area_registry" => "core.area_registry.json", "device_registry" => "core.device_registry.json",
               "entity_registry" => "core.entity_registry.json", "states" => "states.json",
               "automations" => "automations.yaml", "scripts" => "scripts.yaml", "scenes" => "scenes.yaml" }.freeze

  def migracao_site(name) = ActsAsTenant.without_tenant { Site.find_by!(name: name) }

  desc "Importa a casa do Home Assistant em sombra: rake 'migracao:home_assistant[Casa,/pasta/com/os/arquivos]'"
  task :home_assistant, %i[site dir] => :environment do |_, args|
    site = migracao_site(args[:site])
    files = HA_FILES.transform_values { |f| File.join(args[:dir].to_s, f) }.select { |_, p| File.exist?(p) }.transform_values { |p| File.read(p) }
    ActsAsTenant.with_tenant(site.tenant) do
      r = Integrations::HomeAssistantImport.call(site, files)
      puts "áreas novas: #{r.areas} · aparelhos adicionados: #{r.devices_added} · movidos de área: #{r.devices_moved}"
      puts "entidades com par: #{r.entities} · sem par: #{r.unmapped.size} · helpers: #{r.helpers} (fora: #{r.helpers_skipped.size})"
      r.helpers_skipped.each { |h| puts "  helper fora: #{h}" }
      r.scenes.each { |s| puts "cena #{s['name']}: #{s['items']} linha(s)#{", sem par: #{s['lost'].join(', ')}" if s['lost'].any?}" }
      r.items.each { |i| puts "#{i['kind']} #{i['lossless'] ? 'SEM PERDA' : 'COM PERDA'} #{i['enabled'] ? 'ligada' : '-'} #{i['name']}#{": #{i['notes'].join(' | ')}" if i['notes'].any?}" }
    end
  end

  desc "Compara a sombra com um diário já baixado: rake 'migracao:comparar[Casa,home_assistant,/arquivo.json,24]'"
  task :comparar, %i[site source file hours] => :environment do |_, args|
    site = migracao_site(args[:site])
    to = Time.current
    ActsAsTenant.with_tenant(site.tenant) do
      report = Shadow::Compare.call(site, args[:source], from: to - args[:hours].to_i.hours, to: to, entries: JSON.parse(File.read(args[:file])))
      puts report.summary.to_json
    end
  end
end
