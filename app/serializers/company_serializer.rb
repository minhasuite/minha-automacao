class CompanySerializer < ApplicationSerializer
  EDITABLE = %i[name trade_name document phone email city uf ibge_code].freeze

  attributes :id, :name, :trade_name, :document, :phone, :email, :city, :uf, :ibge_code, :plan
  attribute(:members_count) { |t| t.users.size }
  attributes :created_at
end
