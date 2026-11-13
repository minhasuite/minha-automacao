require "net/http"

# HTTP do DVR/NVR na rede de casa (lista de gravações): Digest (MD5 ou SHA-256, pelo
# `Isapi.digest`) ou sem senha. O endereço vem do aparelho cadastrado (técnico+), como
# no `Isapi`. 401 depois do desafio = senha errada (não insiste: o DVR bloqueia).
module Cameras
  class Http
    def initialize(host:, port:, username:, password:)
      @host, @port, @username, @password = host, port.to_i, username.to_s, password.to_s
    end

    def get(path) = call(Net::HTTP::Get, path)

    def post(path, body, type = "application/xml") = call(Net::HTTP::Post, path, body, type)

    private

    def call(klass, path, body = nil, type = nil)
      Net::HTTP.start(@host, @port, open_timeout: 4, read_timeout: 15) do |h|
        res = h.request(build(klass, path, body, type))
        if res.code == "401" && res["www-authenticate"].to_s.start_with?("Digest") && @username.present?
          req = build(klass, path, body, type)
          req["Authorization"] = Isapi.digest(res["www-authenticate"], @username, @password, path, method: klass::METHOD)
          res = h.request(req)
        end
        raise Error, I18n.t("cameras.playback.auth") if res.code == "401"
        raise Error, I18n.t("cameras.playback.http", code: res.code) unless res.is_a?(Net::HTTPSuccess)

        res.body.to_s
      end
    rescue SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError
      raise Error, I18n.t("cameras.playback.offline")
    end

    def build(klass, path, body, type)
      req = klass.new(path)
      if body
        req.body = body
        req["Content-Type"] = type
      end
      req
    end
  end
end
