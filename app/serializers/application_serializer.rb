class ApplicationSerializer
  include Alba::Resource

  # Decimal vira número no JSON (o Alba/ActiveSupport emitiria string).
  def decimal(value) = value&.to_f
end
