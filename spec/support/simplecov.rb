require "simplecov"

SimpleCov.start "rails" do
  skip "/spec/"
  skip "/config/"
  skip "/db/"
  # SDK do meulog copiado (código de terceiro).
  skip "lib/meu_log.rb"

  group "Services", "app/services"
  group "Controllers", "app/controllers"
  group "Models", "app/models"
  group "Jobs", "app/jobs"

  minimum_coverage 90
end
