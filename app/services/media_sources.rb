# Navegador de mídia (ondaC2, C8; o media browser + media sources do HA):
# cada fonte é um plugin em PLUGINS que navega por pastas e devolve itens
# (`Item`); a tela /midia (web e app) e as automações tocam o item em
# qualquer player (ponto que aceita `play_media`). Fonte nova = subclasse de
# `MediaSources::Source` + nome aqui (spec com fonte falsa em
# `spec/services/onda_c2_spec.rb`).
#
# Arquivo local e gravação de câmera chegam ao player por um link assinado
# que vale algumas horas (`file_url`), servido sem sessão por
# `Web::MediaFilesController` — o player (TV, caixa) não tem login.
module MediaSources
  PLUGINS = %w[Local RadioBrowser Dlna Players Recordings].freeze
  KINDS = %w[folder audio video image radio other].freeze
  LINK_TTL = 12.hours
  AUDIO = %w[.mp3 .m4a .aac .ogg .oga .wav .flac .opus].freeze
  VIDEO = %w[.mp4 .mkv .webm .mov .m4v].freeze
  IMAGE = %w[.jpg .jpeg .png .gif .webp].freeze

  # `id`: o caminho (pasta) ou o que tocar (item); `kind` em KINDS.
  Item = Data.define(:id, :title, :kind, :thumb, :subtitle) do
    def initialize(id:, title:, kind:, thumb: nil, subtitle: nil) = super
    def folder? = kind == "folder"
  end
  # Uma página da navegação: título, caminho de volta (nil na raiz da fonte) e itens.
  Page = Data.define(:title, :parent, :items)

  module_function

  def plugins = PLUGINS.map { |name| const_get(name) }
  def for(key) = plugins.find { |s| s.key == key.to_s }
  def available(site) = plugins.select { |s| s.available?(site) }

  # Players do local: tudo que toca endereço (com o grupo de players e a câmera com alto-falante).
  def players(site) = Notifier::Channels::Player.players(site)

  # Endereço que o aparelho da rede alcança (MEDIA_PUBLIC_URL ou APP_HOST na rede de casa).
  def public_url(path)
    return path if path.to_s.match?(%r{\Ahttps?://})

    base = ENV["MEDIA_PUBLIC_URL"].presence || ENV["ASSIST_MEDIA_URL"].presence || "http://#{ENV.fetch('APP_HOST', 'localhost')}"
    "#{base.delete_suffix('/')}#{path}"
  end

  def verifier = Rails.application.message_verifier(:media_file)

  # Link assinado de um arquivo (`kind` = "local" ou "rec"), relativo à raiz da fonte.
  def file_url(site, kind, rel, absolute: true)
    token = verifier.generate([ site.id, kind, rel.to_s ], expires_in: LINK_TTL)
    path = Rails.application.routes.url_helpers.media_file_path(name: File.basename(rel.to_s), t: token)
    absolute ? public_url(path) : path
  end

  # Arquivo do link (nil se vencido, adulterado ou fora da raiz).
  def file_for(token)
    site_id, kind, rel = verifier.verified(token.to_s)
    root = { "local" => Local, "rec" => Recordings }[kind]&.root(site_id) or return
    safe_join(root, rel)
  end

  # Caminho relativo dentro da raiz (nada de "." ou "..").
  def safe_join(root, rel)
    parts = rel.to_s.split("/").compact_blank
    return if parts.any? { |p| p.in?(%w[. ..]) || p.include?("\0") || p.include?("\\") }

    root.join(*parts)
  end

  # Fala do provedor de voz → URL para o player tocar (vale 1 dia).
  def speech_url(site, text)
    res = Ai::Audio.speak(tenant: site.tenant, site: site, text: text.to_s.squish, source: "midia")
    _blob, path = Ai::Audio.store(res.data[:data], res.data[:media_type], "fala-#{Time.current.to_i}")
    public_url(path)
  end

  def kind_of(name)
    ext = File.extname(name.to_s).downcase
    return "audio" if AUDIO.include?(ext)
    return "video" if VIDEO.include?(ext)
    return "image" if IMAGE.include?(ext)

    "other"
  end
end
