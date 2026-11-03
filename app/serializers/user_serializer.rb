class UserSerializer < ApplicationSerializer
  attributes :id, :name, :email, :role
  attribute(:role_label, &:role_label)
  attribute(:company) { |u| { id: u.tenant_id, name: u.tenant.trade_name.presence || u.tenant.name, plan: u.tenant.plan } }
  attribute(:has_password) { |u| u.password_digest.present? }
  attribute(:google_linked) { |u| u.google_uid.present? }
  attribute(:theme) { |u| u.dashboard_prefs.to_h["theme"] } # ondaB2 (B11)
  attributes :created_at
end
