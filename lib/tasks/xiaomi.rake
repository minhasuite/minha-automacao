namespace :xiaomi do
  # JSON na entrada padrão (o token não passa por arquivo nem argumento):
  # {name, host, token, did, model, area, rooms: [{id, name}]}.
  desc "Importa um robô Xiaomi (JSON na entrada padrão) para um local e lê o estado"
  task :importar, %i[local] => :environment do |_, args|
    abort "uso: ... | rake 'xiaomi:importar[Nome do local]'" if args[:local].blank?

    site = ActsAsTenant.without_tenant { Site.find_by!(name: args[:local]) }
    ActsAsTenant.with_tenant(site.tenant) do
      data = JSON.parse($stdin.read)
      r = Miio::Import.call(site, data)
      device = site.devices.find_by!(driver: "xiaomi_miot", external_id: data["did"].to_s)
      puts "#{r[:device]} dispositivo novo, #{r[:points]} pontos novos; #{Drivers::XiaomiMiot.poll(device)} propriedades lidas"
    end
  end
end
