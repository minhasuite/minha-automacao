require "net/http"

# Gravação própria das câmeras (ondaC2, C10; a gravação do Frigate sem o
# Frigate): o go2rtc entrega um MP4 de N segundos (`/api/stream.mp4?duration=`)
# e o arquivo fica em `RECORDINGS_DIR/<local>/<ponto>/<dia>/<hora>-<motivo>.mp4`
# (padrão storage/recordings), com o índice em `camera_recordings`.
#
# Por câmera (ponto `stream` do go2rtc), em `address.record`:
# - `mode`: "off", "continuous" (trechos de SEGMENT_S, um atrás do outro,
#   pelo `Recordings::Recorder` no worker) ou "events" (movimento de um ponto
#   `motion` do mesmo aparelho grava `event_s` segundos);
# - `retention_days`: o que passou disso some (`purge!`, a cada hora).
# Gravar na hora: comando `record` (automação, voz, tela) com os segundos.
module Recordings
  class Error < StandardError; end

  MODES = %w[off continuous events].freeze
  SEGMENT_S = 60
  DEFAULTS = { "mode" => "off", "retention_days" => 7, "event_s" => 30 }.freeze
  MAX_RETENTION = 365

  module_function

  def root(site_id) = Pathname(ENV["RECORDINGS_DIR"].presence || Rails.root.join("storage/recordings")).join(site_id.to_s)
  def settings(point) = DEFAULTS.merge(point.address["record"].to_h.slice(*DEFAULTS.keys))
  def cameras = Point.joins(:device).where(capability: "stream", disabled: false, devices: { driver: "go2rtc", disabled: false })

  # Formulário → address.record (e o ponto passa a aceitar `record`).
  def configure!(point, form)
    mode = form["mode"].to_s.presence_in(MODES) || "off"
    days = Integer(form["retention_days"].to_s.presence || 7, exception: false).to_i.clamp(1, MAX_RETENTION)
    secs = Integer(form["event_s"].to_s.presence || 30, exception: false).to_i.clamp(5, Points::Command::MAX_RECORD_S)
    point.update!(address: point.address.merge("record" => { "mode" => mode, "retention_days" => days, "event_s" => secs }))
  end

  # Grava `seconds` agora (bloqueia esse tempo: use pela fila ou pelo Recorder).
  def record!(point, seconds, trigger)
    raise Error, "Sem go2rtc." unless Drivers::Go2rtc.url

    started = Time.current
    rel = "#{point.id}/#{started.strftime('%Y-%m-%d')}/#{started.strftime('%H%M%S')}-#{trigger}.mp4"
    file = root(point.site_id).join(rel)
    FileUtils.mkdir_p(file.dirname)
    Drivers::Go2rtc.prepare(point)
    download(point, seconds, file)
    return FileUtils.rm_f(file) && nil unless file.size?

    CameraRecording.create!(site_id: point.site_id, tenant_id: point.tenant_id, point: point, started_at: started,
                            duration_s: (Time.current - started).round.clamp(1, seconds + 30), bytes: file.size, trigger: trigger, file: rel)
  rescue Drivers::Go2rtc::Error => e
    raise Error, e.message
  end

  def download(point, seconds, file)
    uri = URI.join(Drivers::Go2rtc.url, "/api/stream.mp4")
    uri.query = URI.encode_www_form(src: point.id, duration: seconds)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: seconds + 20) do |http|
      http.request(Net::HTTP::Get.new(uri)) do |res|
        raise Error, "go2rtc respondeu #{res.code}." unless res.is_a?(Net::HTTPSuccess)

        File.open(file, "wb") { |f| res.read_body { |chunk| f.write(chunk) } }
      end
    end
  rescue SystemCallError, SocketError, Timeout::Error, IOError => e
    raise Error, "go2rtc fora do ar (#{e.class.name.demodulize})." unless file.size?
  end

  # Movimento num aparelho: as câmeras dele em "events" gravam (uma de cada vez por câmera).
  def motion!(point)
    return unless point.capability == "motion" && point.value == true

    cameras.where(device_id: point.device_id).find_each do |cam|
      s = settings(cam)
      next unless s["mode"] == "events"
      next if CameraRecording.where(point_id: cam.id, trigger: "event").exists?(started_at: s["event_s"].seconds.ago..)

      CameraRecordJob.perform_later(cam.id, s["event_s"], "event")
    end
  end

  # Retenção: apaga o índice e o arquivo do que passou do prazo de cada câmera.
  def purge!(now = Time.current)
    ActsAsTenant.without_tenant do
      Point.where(id: CameraRecording.select(:point_id)).sum do |point|
        old = CameraRecording.where(point: point).where(started_at: ...(now - settings(point)["retention_days"].days))
        old.find_each { |r| FileUtils.rm_f(r.path) if r.path }
        old.delete_all
      end
    end
  end

  # Dias com gravação de uma câmera (mais novo primeiro) e trechos de um dia.
  def days(point) = CameraRecording.where(point: point).order(started_at: :desc).pluck(:started_at).map(&:to_date).uniq
  def of_day(point, day) = CameraRecording.where(point: point, started_at: day.all_day).order(:started_at)
end
