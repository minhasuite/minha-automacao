class SiteMembershipSerializer < ApplicationSerializer
  attributes :id, :site_id, :user_id, :role, :area_ids, :expires_at
  attribute(:user) { |m| { name: m.user.name, email: m.user.email } }
  attributes :created_at
end
