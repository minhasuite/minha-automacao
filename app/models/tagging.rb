class Tagging < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tag
  belongs_to :taggable, polymorphic: true
end
