class CommandSerializer < ApplicationSerializer
  attribute(:command_id, &:id)
  attributes :id, :point_id, :command, :value, :status, :source, :error, :user_id, :client_uuid,
             :created_at, :sent_at, :confirmed_at
  # Valor do ponto depois do comando (o app não precisa de outro GET).
  attribute(:point_value) { |c| c.point.value }
end
