require "rails_helper"

# Fila e jobs (Configurações → Fila, GET /api/v1/system/queue; docs/fila.md).
RSpec.describe "Fila e jobs" do
  let(:user) { create(:user, role: "owner") }
  let(:tenant) { user.tenant }
  let!(:site) { within(tenant) { create(:site, name: "Casa") } }
  let(:tuya) { within(tenant) { create(:device, site: site, name: "Interruptor", driver: "tuya_local") } }
  let(:virtual) { within(tenant) { create(:device, site: site, name: "Virtual", driver: "virtual") } }
  let(:luz) { within(tenant) { create(:point, device: tuya, name: "Luz da sala") } }
  let(:helper) { within(tenant) { create(:point, device: virtual, name: "Modo noite") } }
  let(:now) { Time.zone.parse("2026-11-08 12:00:00") }

  def sign_in(u = user) = post("/entrar", params: { email: u.email, password: "12345678" })

  def command!(point, ago:, queue: nil, device: nil, status: "confirmed", error: nil)
    created = now - ago
    sent = queue && created + queue
    within(tenant) do
      Command.create!(site: site, point: point, command: "turn_on", status: status, source: "web", error: error,
                      created_at: created, sent_at: sent, confirmed_at: (sent + device if sent && device))
    end
  end

  def job!(klass = "ExecuteCommandJob", at: now - 1.minute, args: [ "abc" ])
    SolidQueue::Job.create!(queue_name: "default", class_name: klass, scheduled_at: at, created_at: at,
                            arguments: { "job_class" => klass, "arguments" => args })
  end

  def failed_job!(klass = "PollDeviceJob")
    job = job!(klass)
    job.ready_execution.destroy!
    error = RuntimeError.new("aparelho não respondeu")
    error.set_backtrace([ "app/jobs/poll_device_job.rb:10:in 'perform'", "lib/tuya/connection.rb:42" ])
    job.failed_with(error)
    SolidQueue::FailedExecution.find_by!(job_id: job.id)
  end

  around { |ex| travel_to(now) { ex.run } }

  describe "latência dos comandos" do
    before do
      # Última hora, tuya_local: fila 1, 2, 3, 4, 10 s; aparelho 1, 1, 1, 1, 5 s; e um que expirou.
      [ [ 1, 1 ], [ 2, 1 ], [ 3, 1 ], [ 4, 1 ], [ 10, 5 ] ].each_with_index { |(q, d), i| command!(luz, ago: (i + 1).minutes, queue: q, device: d) }
      command!(luz, ago: 30.minutes, status: "expired")
      # Só nas 24 h: o driver virtual (na hora) e uma falha com erro.
      command!(helper, ago: 2.hours, queue: 0, device: 0.1)
      command!(luz, ago: 3.hours, queue: 0.5, status: "failed", error: "timeout no 6668")
    end

    it "calcula p50/p95/máx de fila e aparelho por janela e por driver" do
      lat = within(tenant) { QueueMonitor.command_latency(now) }
      hour = lat["1h"]
      expect(hour[:total][:count]).to eq(6)
      expect(hour[:total][:expired]).to eq(1)
      expect(hour[:total][:queue]).to eq(p50: 3.0, p95: 8.8, max: 10.0)
      expect(hour[:total][:device]).to eq(p50: 1.0, p95: 4.2, max: 5.0)
      expect(hour[:drivers].map { _1[:driver] }).to eq([ "tuya_local" ])

      day = lat["24h"]
      expect(day[:total][:count]).to eq(8)
      expect(day[:total][:failed]).to eq(1)
      expect(day[:drivers].map { [ _1[:driver], _1[:count] ] }).to eq([ [ "tuya_local", 7 ], [ "virtual", 1 ] ])
      expect(day[:drivers].last[:device]).to eq(p50: 0.1, p95: 0.1, max: 0.1)

      recent = within(tenant) { QueueMonitor.recent_commands }
      expect(recent.first).to include(point: "Luz da sala", driver: "tuya_local", queue_s: 1.0, device_s: 1.0)
      failed = within(tenant) { QueueMonitor.failed_commands(now) }
      expect(failed.map { _1[:status] }).to eq(%w[expired failed])
      expect(failed.last[:error]).to eq("timeout no 6668")
    end

    it "sem comandos devolve zero e nada de número inventado" do
      within(tenant) { Command.delete_all }
      lat = within(tenant) { QueueMonitor.command_latency(now) }
      expect(lat["1h"]).to eq(total: { count: 0, failed: 0, expired: 0, queue: { p50: nil, p95: nil, max: nil }, device: { p50: nil, p95: nil, max: nil } }, drivers: [])
    end

    it "a tela mostra o resumo, a latência, os últimos comandos e recarrega sozinha" do
      sign_in
      get "/configuracoes/fila"
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Latência dos comandos", "Última hora", "tuya_local", "Luz da sala", "timeout no 6668",
                              "95% saíram da fila em até 8,8 s", "data-controller=\"ss-reload\"", "data-ss-reload-every-value=\"10000\"")
      expect(body).to include("Fila e jobs").and include("/configuracoes/fila")
    end

    it "a API devolve o resumo e a latência no envelope {data, meta}" do
      get "/api/v1/system/queue", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(data.keys).to include("summary", "command_latency", "processes", "recurring", "jobs")
      expect(data.dig("command_latency", "1h", "total", "queue")).to eq("p50" => 3.0, "p95" => 8.8, "max" => 10.0)
      expect(json["meta"]).to include("windows" => %w[1h 24h], "unit" => "s")
    end
  end

  describe "jobs" do
    it "resume a fila, estatística por classe e as listas com abas" do
      job!("RunSchedulesJob") # pendente
      done = job!("RunSchedulesJob", at: now - 10.minutes)
      done.ready_execution.destroy!
      done.update!(finished_at: now - 10.minutes + 2.5.seconds)
      later = job!("PointHoldJob", at: now + 5.minutes, args: [ { "_aj_globalid" => "gid://minha-automacao/Point/0f3a9c1e-1111-2222-3333-444455556666" } ])
      running = job!("PollDeviceJob", at: now - 30.seconds)
      running.ready_execution.destroy!
      proc = SolidQueue::Process.create!(kind: "Worker", name: "worker-abc", pid: 42, hostname: "dell", last_heartbeat_at: now - 5.seconds, created_at: now - 1.hour)
      SolidQueue::ClaimedExecution.create!(job_id: running.id, process_id: proc.id, created_at: now - 20.seconds)
      failed_job!

      s = QueueMonitor.summary(now)
      expect(s).to include(ready: 1, claimed: 1, scheduled: 1, failed: 1, finished_24h: 1, processes_alive: 1, processes: 1)
      stats = QueueMonitor.job_stats(now)
      expect(stats.find { _1[:job] == "RunSchedulesJob" }).to include(count: 1, failed: 0, avg_s: 2.5, p95_s: 2.5, max_s: 2.5)
      expect(stats.find { _1[:job] == "PollDeviceJob" }).to include(count: 0, failed: 1)
      expect(QueueMonitor.running(now).first).to include(job: "PollDeviceJob", waited_s: 10.0, running_s: 20.0, process: "worker-abc (42)")
      expect(QueueMonitor.scheduled.first).to include(job: "PointHoldJob", args: "Point 0f3a9c1e")
      expect(QueueMonitor.failed.first).to include(error_class: "RuntimeError", message: "aparelho não respondeu")
      expect(QueueMonitor.finished(now).first).to include(total_s: 2.5)
      expect(later).to be_persisted

      sign_in
      get "/configuracoes/fila" # com erro, abre na aba Com erro
      expect(response.body).to include("aparelho não respondeu", "app/jobs/poll_device_job.rb:10", "Tentar de novo", "Descartar", "worker-abc")
      %w[execucao agendados concluidos].each do |aba|
        get "/configuracoes/fila", params: { aba: aba }
        expect(response).to have_http_status(:ok)
      end
      get "/configuracoes/fila", params: { aba: "agendados" }
      expect(response.body).to include("PointHoldJob", "Point 0f3a9c1e")
      get "/configuracoes/fila", params: { aba: "execucao" }
      expect(response.body).to include("PollDeviceJob", "worker-abc (42)")
    end

    it "tentar de novo põe o job com erro de volta na fila; descartar apaga" do
      sign_in
      fe = failed_job!
      post "/configuracoes/fila/erros/#{fe.id}/tentar"
      expect(response).to redirect_to("/configuracoes/fila?aba=erros")
      expect(SolidQueue::FailedExecution.count).to eq(0)
      expect(SolidQueue::ReadyExecution.where(job_id: fe.job_id)).to exist

      fe2 = failed_job!("FirmwareCheckJob")
      delete "/configuracoes/fila/erros/#{fe2.id}"
      expect(flash[:notice]).to eq("Job descartado.")
      expect(SolidQueue::Job.where(id: fe2.job_id)).not_to exist
      expect(SolidQueue::FailedExecution.count).to eq(0)
    end
  end

  describe "quem vê" do
    it "só o dono, numa instalação só: o resto leva 404 na web e 403 na API" do
      admin = create(:user, tenant: tenant, role: "admin")
      sign_in(admin)
      get "/configuracoes/fila"
      expect(response).to have_http_status(:not_found)
      fe = failed_job!
      post "/configuracoes/fila/erros/#{fe.id}/tentar"
      expect(response).to have_http_status(:not_found)
      expect(SolidQueue::FailedExecution.count).to eq(1)
      get "/api/v1/system/queue", headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)

      get "/configuracoes/saude"
      expect(response.body).not_to include("/configuracoes/fila")

      create(:user) # segunda instalação
      sign_in
      get "/configuracoes/fila"
      expect(response).to have_http_status(:not_found)
      get "/api/v1/system/queue", headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
    end

    it "o dono acha a Fila no menu de Configurações e na Saúde" do
      sign_in
      get "/configuracoes/saude"
      expect(response.body).to include("data-health-link=\"queue\"")
      get "/configuracoes/logs"
      expect(response.body).to include("href=\"/configuracoes/fila\"")
    end
  end
end
