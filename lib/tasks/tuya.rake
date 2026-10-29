namespace :tuya do
  desc "Importa os aparelhos do LocalTuya (JSON de core.config_entries → data.devices) para um local"
  task :importar, %i[arquivo local] => :environment do |_, args|
    abort "uso: rake 'tuya:importar[arquivo.json,Nome do local]'" if args[:arquivo].blank? || args[:local].blank?

    site = ActsAsTenant.without_tenant { Site.find_by!(name: args[:local]) }
    ActsAsTenant.with_tenant(site.tenant) do
      r = Tuya::Import.call(site, JSON.parse(File.read(args[:arquivo])))
      puts "#{r.devices} dispositivos, #{r.points} pontos novos"
      r.skipped.each { |s| puts "ignorado: #{s}" }
    end
  end
end
