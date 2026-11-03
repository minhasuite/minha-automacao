# Servidor MCP (ondaB1, B7): `POST /mcp` com `Authorization: Bearer <token>`
# (token MCP do local, criado em Local → Assistente de voz → MCP). JSON-RPC
# 2.0 de ida e volta (transporte "streamable HTTP" sem fluxo SSE: GET = 405).
# O que cada ferramenta faz e quem pode está em Assist::Mcp.
class McpController < ActionController::API
  MAX_BODY = 256.kilobytes

  before_action :authenticate!

  def create
    return head(:payload_too_large) if request.content_length.to_i > MAX_BODY

    message = JSON.parse(request.raw_post.presence || "null")
    reply = ActsAsTenant.with_tenant(@token.user.tenant) do
      Current.user = @token.user
      site = Site.find_by(id: @token.site_id) or next Assist::Mcp.error(nil, -32_001, "Local removido.")
      Assist::Mcp.handle(message, site: site, user: @token.user)
    end
    reply ? render(json: reply) : head(:accepted)
  rescue JSON::ParserError
    render json: Assist::Mcp.error(nil, -32_700, "Parse error"), status: :bad_request
  end

  def show = head(:method_not_allowed)

  private

  def authenticate!
    plain = request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
    @token = ApiToken.find_mcp(plain)
    return render(json: { error: "unauthorized" }, status: :unauthorized) unless @token && !@token.user.disabled? && @token.site_id

    @token.touch_usage!
  end
end
