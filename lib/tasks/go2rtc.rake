namespace :go2rtc do
  # A lista vem pela entrada padrão para a senha não passar por arquivo nem
  # pela linha de comando: [{name, host, port, username, password, area,
  # streams: [{name, path}]}].
  desc "Importa câmeras (JSON na entrada padrão) para um local e sincroniza o go2rtc"
  task :importar, %i[local] => :environment do |_, args|
    abort "uso: ... | rake 'go2rtc:importar[Nome do local]'" if args[:local].blank?

    site = ActsAsTenant.without_tenant { Site.find_by!(name: args[:local]) }
    ActsAsTenant.with_tenant(site.tenant) do
      r = Drivers::Go2rtc.import!(site, JSON.parse($stdin.read))
      puts "#{r[:devices]} dispositivos, #{r[:points]} câmeras novas"
    end
    puts "go2rtc: #{Drivers::Go2rtc.sync!.inspect} streams"
  end
end
