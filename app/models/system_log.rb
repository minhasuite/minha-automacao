# Log do sistema resumido (ondaA2 A12; o "Logs" do HA): avisos e erros do
# servidor agrupados por mensagem (contagem, primeira e última vez). A fonte
# vem do prefixo que o código já usa ("[tuya] ...") ou é "core". Chega pelo
# `SystemLog::Sink` ligado no Rails.logger (fora do teste). É do servidor, não
# da instalação: só o dono vê, e só num servidor de uma instalação só.
class SystemLog < ApplicationRecord
  LEVELS = %w[warn error fatal].freeze
  KEEP = 500
  SOURCE = /\A\[([\w -]{1,40})\]\s*/

  scope :recent, -> { order(last_at: :desc) }

  def self.visible_to?(user) = user&.owner? && Tenant.count == 1

  # Grava ou soma no igual (números trocados por # para juntar "falhou 3x" e "falhou 4x").
  # Nunca levanta: log não pode derrubar quem loga.
  def self.record!(level, message, source: nil, at: Time.current)
    msg = message.to_s.strip.truncate(2000)
    return if msg.empty?

    level = level.to_s.downcase
    source ||= msg[SOURCE, 1]&.strip&.downcase&.tr(" -", "__") || "core"
    digest = Digest::SHA256.hexdigest("#{level}|#{source}|#{msg.gsub(/\d+/, '#')}")[0, 32]
    upsert({ level: level, source: source, message: msg, digest: digest, count: 1, first_at: at, last_at: at },
           unique_by: :digest, on_duplicate: Arel.sql("count = system_logs.count + 1, last_at = EXCLUDED.last_at, message = EXCLUDED.message"))
    prune! if rand(50).zero?
  rescue StandardError
    nil
  end

  def self.prune! = where(id: recent.offset(KEEP).select(:id)).delete_all

  def self.to_text(scope) = scope.map { |l| "#{l.last_at.iso8601} #{l.level.upcase} [#{l.source}] (#{l.count}x) #{l.message}" }.join("\n")

  # Logger que só passa WARN ou pior, gravando numa thread à parte (fora da
  # transação de quem logou). Uma thread por processo (Puma e fila fazem fork).
  class Sink < ::Logger
    NAMES = %w[debug info warn error fatal error].freeze

    def initialize
      super(nil, level: :warn)
      @queue = Queue.new
    end

    def add(severity, message = nil, progname = nil)
      return true if severity.to_i < level

      message = block_given? ? yield : progname if message.nil?
      text = message.is_a?(Exception) ? "#{message.class}: #{message.message}" : message.to_s
      @queue << [ NAMES.fetch(severity.to_i, "error"), text, Time.current ]
      worker
      true
    end

    private

    def worker
      return if @pid == Process.pid && @thread&.alive?

      @pid = Process.pid
      @thread = Thread.new do
        loop do
          lvl, text, at = @queue.pop
          ActiveRecord::Base.connection_pool.with_connection { SystemLog.record!(lvl, text, at: at) }
        rescue StandardError
          nil
        end
      end
    end
  end
end
