class NotificationSerializer < ApplicationSerializer
  attributes :id, :kind, :title, :body, :data, :read_at, :created_at
end
