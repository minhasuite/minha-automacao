# Resultado de uma comparação (F10, Shadow::Compare): por automação, o que a
# fonte de referência fez de verdade × o que a sombra teria feito.
# `rows` = [{name, ref, automation_id, status, ref_runs, runs, ref_effects,
# effects, missing, extra, ignored, detail}]; `summary` = {status → quantos}.
class ShadowReport < ApplicationRecord
  acts_as_tenant :tenant

  STATUSES = { "same" => "Igual", "extra" => "MA a mais", "missing" => "MA a menos", "different" => "Diferente",
               "unmapped" => "Sem par no MA", "idle" => "Sem disparo" }.freeze
  TONES = { "same" => "success", "extra" => "warn", "missing" => "warn", "different" => "danger", "unmapped" => "muted", "idle" => "muted" }.freeze

  belongs_to :site

  scope :recent, -> { order(created_at: :desc) }

  def self.status_label(s) = STATUSES.fetch(s, s)

  def to_csv
    require "csv"
    CSV.generate(col_sep: ";") do |csv|
      csv << [ "Automação", "Referência", "Status", "Disparos na referência", "Disparos na sombra", "Só na referência", "Só na sombra", "Detalhe" ]
      rows.each do |r|
        csv << [ r["name"], r["ref"], self.class.status_label(r["status"]), r["ref_runs"], r["runs"], Array(r["missing"]).join(", "),
                 Array(r["extra"]).join(", "), r["detail"] ]
      end
    end
  end
end
