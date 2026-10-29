namespace :alexa do
  # Cookies da sessão na entrada padrão (o arquivo de cookies do alexa_media
  # do HA ou {nome: valor}); nunca em arquivo do repositório nem argumento.
  desc "Importa a conta da Alexa (cookies na entrada padrão) e as Echo de um local"
  task :importar, %i[local] => :environment do |_, args|
    abort "uso: ... | rake 'alexa:importar[Nome do local]'" if args[:local].blank?

    site = ActsAsTenant.without_tenant { Site.find_by!(name: args[:local]) }
    ActsAsTenant.with_tenant(site.tenant) do
      r = Alexa::Import.call(site, $stdin.read)
      puts "#{r[:echos]} Echo na conta, #{r[:devices]} dispositivos novos, #{r[:points]} pontos novos"
    end
  end
end
