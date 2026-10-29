namespace :licencas do
  desc "Informa ao licenciamento central todas as assinaturas que existem (retroativo)"
  task enviar_tudo: :environment do
    abort "LICENCAS_URL/LICENCAS_API_KEY vazias" unless Licencas::Client.enabled?

    puts "#{LicencasEnviarTudoJob.perform_now} empresas enviadas"
  end
end
