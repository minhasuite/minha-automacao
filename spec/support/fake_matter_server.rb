# Servidor Matter falso (Pacote 1): faz o papel do WsClient conectado ao
# python-matter-server. Guarda os pedidos e responde pelo comando; cada
# conexão recebe o server_info e cada resposta vem depois de um evento
# `attribute_updated`, como no servidor de verdade.
class FakeMatterServer
  NODE = {
    "node_id" => 7, "available" => true,
    "attributes" => { "0/40/1" => "Acme", "0/40/3" => "Lâmpada A19", "0/40/5" => "Luz do escritório",
                      "1/6/0" => true, "1/8/0" => 127, "2/1026/0" => 2150, "2/1030/0" => 1, "3/69/0" => true,
                      "4/1024/0" => 20_001, "5/47/12" => 180, "6/258/14" => 2500, "1/29/0" => [] }
  }.freeze

  attr_reader :sent

  def initialize(nodes: [ NODE ], events: [], fail: nil)
    @nodes = nodes
    @inbox = events.dup
    @fail = fail
    @sent = []
  end

  def connect = tap { @inbox.unshift({ "fabric_id" => 1, "schema_version" => 11 }) }

  def send_json(msg)
    @sent << msg
    return @inbox << { "message_id" => msg["message_id"], "error_code" => 1, "details" => @fail } if @fail

    @inbox << { "event" => "attribute_updated", "data" => [ 7, "1/6/0", false ] }
    result = { "get_nodes" => @nodes, "start_listening" => @nodes, "commission_with_code" => { "node_id" => 8 } }[msg["command"]]
    @inbox << { "message_id" => msg["message_id"], "result" => result }
  end

  def read_json(_timeout = nil) = @inbox.shift
  def closed? = @inbox.empty?
  def close = nil
end
