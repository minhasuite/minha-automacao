# Mapa (paridade com o HA): pessoas e zonas do local. Onde as pessoas estão é
# dado sensível: só morador para cima vê (visitante e operador, não).
module Maps
  MIN_ROLE = "resident".freeze

  module_function

  def roles = SiteMembership::ROLES.drop(SiteMembership::ROLES.index(MIN_ROLE))
  def allowed_role?(role) = roles.include?(role.to_s)
  def allowed?(user) = user.admin? || SiteMembership.active.where(user_id: user.id, role: roles).exists?
end
