class ApplicationJob < ActiveJob::Base
  # Registro sumiu entre o enqueue e a execução: nada a fazer.
  discard_on ActiveJob::DeserializationError
end
