# O que a sombra (F10) segurou: uma linha por ação que teria saído
# (comando, aviso, fala, HTTP, IA...) ou por comando interno que rodou de
# verdade (`executed`: helper e script, que não tocam aparelho).
# `effects` = [{point_id, command, value}] para o comparador.
class ShadowAction < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :site
  belongs_to :automation, optional: true
  belongs_to :automation_run, optional: true
  belongs_to :scene, optional: true

  scope :recent, -> { order(created_at: :desc) }

  def origin_name = automation&.name || scene&.name || I18n.t("automations.shadow.origin_rule")
  def origin_kind = automation&.kind_label || I18n.t(scene ? "automations.shadow.origin_scene" : "automations.shadow.origin_primitive")
end
