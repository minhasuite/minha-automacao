module Integrations
  # resto2: pareamento que espera o código que a TV mostra (Android TV Remote,
  # Apple TV). A conexão aberta no primeiro Continuar fica aqui até a pessoa
  # digitar o código (no segundo Continuar) e some sozinha em 3 min.
  # ponytail: memória do processo web (o Puma do MA roda sem workers); com workers, levar para um processo só.
  module PendingPairing
    TTL = 180
    @all = {}
    @lock = Mutex.new

    class << self
      # `session` responde a `close`.
      def put(id, session)
        @lock.synchronize do
          sweep
          close(@all.delete(id)&.first)
          @all[id] = [ session, Time.now + TTL ]
        end
      end

      def take(id) = @lock.synchronize { sweep && @all.delete(id)&.first }

      private

      def sweep
        @all.delete_if { |_, (s, at)| at < Time.now && close(s).nil? }
        true
      end

      def close(session)
        session&.close
        nil
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
    end
  end
end
