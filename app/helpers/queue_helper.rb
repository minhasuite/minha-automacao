# Fila e jobs (Configurações → Fila): durações em segundos para a tela.
module QueueHelper
  # nil → "—"; < 1 s em ms; < 1 min com uma casa; acima, "3 min 5 s".
  def queue_secs(secs)
    return "—" if secs.nil?

    secs = secs.to_f
    if secs < 1 then t("queue.units.ms", n: (secs * 1000).round)
    elsif secs < 60 then t("queue.units.s", n: number_with_precision(secs, precision: 1, strip_insignificant_zeros: true))
    else t("queue.units.min", m: (secs / 60).floor, s: (secs % 60).round)
    end
  end

  def queue_time(time) = time ? l(time, format: t("queue.time_format")) : "—"

  def queue_status_tone(status) = { "confirmed" => "success", "failed" => "danger", "expired" => "warn" }.fetch(status, "muted")
end
