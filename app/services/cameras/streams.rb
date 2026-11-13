# Limite de vídeos abertos ao mesmo tempo por pessoa (cameras2): cada ao vivo pelo
# proxy (MSE por WebSocket ou HLS) ocupa uma vaga até fechar ou ficar TTL s sem uso.
# Fica no cache (Solid Cache em produção: vale para os dois processos do Puma); a
# corrida entre processos pode deixar passar um a mais, o que não faz mal.
module Cameras
  module Streams
    TTL = 45
    DEFAULT_MAX = 8
    LOCK = Mutex.new

    module_function

    def max = ENV.fetch("CAMERA_STREAMS_PER_USER", DEFAULT_MAX).to_i.clamp(1, 64)

    def cache_key(user_id) = "cameras:streams:#{user_id}"

    def active(user_id)
      now = Time.current.to_i
      Rails.cache.read(cache_key(user_id)).to_h.select { |_, exp| exp.to_i > now }
    end

    # Ocupa (ou renova) a vaga `key`; false quando a pessoa já está no limite.
    def acquire(user_id, key)
      LOCK.synchronize do
        list = active(user_id)
        return false if !list.key?(key) && list.size >= max

        list[key] = Time.current.to_i + TTL
        Rails.cache.write(cache_key(user_id), list, expires_in: TTL * 2)
        true
      end
    end

    # Renova sem barrar (o vídeo já estava aberto).
    def touch(user_id, key)
      LOCK.synchronize do
        list = active(user_id)
        list[key] = Time.current.to_i + TTL
        Rails.cache.write(cache_key(user_id), list, expires_in: TTL * 2)
      end
    end

    def release(user_id, key)
      LOCK.synchronize do
        list = active(user_id)
        Rails.cache.write(cache_key(user_id), list.except(key), expires_in: TTL * 2) if list.key?(key)
      end
    end

    def count(user_id) = active(user_id).size
  end
end
