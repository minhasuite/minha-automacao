# Docker em memória com a mesma interface de Supervisor::Docker.
class FakeDocker
  attr_reader :containers_by_id, :volumes, :calls, :pulled

  def initialize
    @containers_by_id = {}
    @volumes = {}
    @calls = []
    @pulled = []
    @seq = 0
  end

  def add(labels:, state: "running", policy: "no", env: [], health: nil)
    id = "c#{@seq += 1}"
    @containers_by_id[id] = { "Id" => id, "Config" => { "Labels" => labels, "Env" => env },
                              "State" => { "Status" => state, "Health" => (health && { "Status" => health }) }.compact,
                              "HostConfig" => { "RestartPolicy" => { "Name" => policy } } }
    id
  end

  def containers(filters)
    @containers_by_id.values.select do |c|
      filters.all? { |f| k, v = f.split("=", 2); c.dig("Config", "Labels").key?(k) && (v.nil? || c.dig("Config", "Labels")[k] == v) }
    end
  end

  def inspect(id) = @containers_by_id.fetch(id)
  def pull(ref) = @pulled << ref
  def logs(_id, lines) = "linha 1\nlinha 2 (#{lines})"
  def memory_mb(_id) = 42.5

  def call(method, path, body: nil, query: {}, timeout: 30) # rubocop:disable Lint/UnusedMethodArgument
    @calls << [ method, path, body, query ]
    case [ method, path ]
    in [ :post, "/containers/create" ]
      id = add(labels: body["Labels"], policy: body.dig("HostConfig", "RestartPolicy", "Name"), env: body["Env"], state: "created")
      [ 201, { "Id" => id } ]
    in [ :post, %r{/containers/(\w+)/start} ] then @containers_by_id[$1]["State"]["Status"] = "running"
    in [ :post, %r{/containers/(\w+)/stop} ] then @containers_by_id[$1]["State"]["Status"] = "exited"
    in [ :post, %r{/containers/(\w+)/update} ] then @containers_by_id[$1]["HostConfig"]["RestartPolicy"] = { "Name" => body[:RestartPolicy][:Name] }
    in [ :delete, %r{/containers/(\w+)} ] then @containers_by_id.delete($1)
    in [ :post, "/volumes/create" ] then @volumes[body[:Name]] = body[:Labels]
    in [ :get, "/volumes" ] then [ 200, { "Volumes" => @volumes.map { |n, l| { "Name" => n, "Labels" => l } } } ]
    in [ :delete, %r{/volumes/(.+)} ] then @volumes.delete($1)
    else [ 200, {} ]
    end
  end
end
