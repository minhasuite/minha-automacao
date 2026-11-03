module Onvif
  # Movimento das câmeras ONVIF (PullPoint) no processo worker, no padrão do
  # Tuya::Listener: uma thread por câmera que tem ponto `motion` com
  # `address.onvif = "motion"`. Assina os eventos, pede mensagens em espera
  # longa (20 s), renova a assinatura antes de vencer e passa cada mudança
  # para `Point#report!`. Caiu: o ponto fica `unavailable` e tenta de novo com
  # espera crescente (até 60 s). ONVIF_LISTENER=off desliga.
  class Listener
    SCAN_EVERY = 60
    RENEW_EVERY = 300
    TERMINATION = 600
    MAX_BACKOFF = 60

    @threads = Concurrent::Map.new

    class << self
      def start
        return if @supervisor&.alive?

        @supervisor = Thread.new do
          loop do
            scan
            sleep SCAN_EVERY
          end
        end
      end

      def motion_points = Point.joins(:device).where(disabled: false, devices: { driver: "go2rtc", disabled: false }).where("points.address->>'onvif' IS NOT NULL")

      def scan
        wanted = Rails.application.executor.wrap { ActsAsTenant.without_tenant { motion_points.distinct.pluck(:device_id) } }
        (@threads.keys - wanted).each { |id| @threads.delete(id)&.kill }
        wanted.each { |id| @threads[id] = Thread.new { listen(id) } unless @threads[id]&.alive? }
      rescue StandardError => e
        Rails.error.report(e, handled: true)
      end

      def listen(device_id)
        failures = 0
        loop do
          failures = run_once(device_id) ? 0 : failures + 1
          sleep [ 2**failures, MAX_BACKOFF ].min
        end
      end

      # Uma assinatura: true se chegou a assinar. `rounds` limita o laço (specs).
      def run_once(device_id, rounds: nil)
        client = sub = nil
        with_device(device_id) do |d|
          client = Client.new(host: d.address["host"], port: d.address["onvif_port"], username: d.address["username"], password: d.credential)
        end
        return true unless client

        client.sync_clock!
        events = client.services["events"] or raise Error, "A câmera não tem serviço de eventos."
        sub = client.subscribe(events, seconds: TERMINATION)
        renewed = monotonic
        n = 0
        until rounds && (n += 1) > rounds
          client.pull(sub).each { |key, on| report(device_id, on, key: key) }
          next unless monotonic - renewed > RENEW_EVERY

          client.renew(sub, seconds: TERMINATION)
          renewed = monotonic
        end
        true
      rescue Error => e
        Rails.logger.warn("[onvif] #{device_id}: #{e.message}")
        report(device_id, nil, quality: "unavailable")
        !sub.nil?
      ensure
        client.unsubscribe(sub) if sub
      end

      # resto: `key` = evento (motion, tamper, line…); sem chave (caiu) vale para todos os pontos ONVIF.
      def report(device_id, moving, quality: "good", key: nil)
        with_device(device_id) do |d|
          d.update_columns(status: "online", last_seen_at: Time.current) if quality == "good"
          d.points.select { |p| p.address["onvif"].present? && (key.nil? || p.address["onvif"] == key) }.each do |p|
            value = moving.nil? ? p.value : moving
            p.report!(value, quality: quality) unless p.value == value && p.quality == quality
          end
        end
      end

      private

      def with_device(device_id)
        Rails.application.executor.wrap do
          device = ActsAsTenant.without_tenant { Device.find_by(id: device_id) }
          device && ActsAsTenant.with_tenant(device.tenant) { yield device }
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
