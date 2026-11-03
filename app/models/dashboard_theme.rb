# Tema criado pela pessoa (ondaB2 B11; os `themes:` do HA, com editor e
# prévia): as duas cores da marca, o papel de parede (brilhos, malha, cor
# lisa ou nenhum), cartões de vidro e a fonte. Vale para a empresa toda e
# entra na galeria ao lado dos temas prontos (`Dashboards::Themes.all`);
# responde como um plugin de tema (key, label, accent, accent2, wallpaper,
# glass, css), então painel, visão, noite e app não mudam.
class DashboardTheme < ApplicationRecord
  acts_as_tenant :tenant

  HEX = Dashboards::Themes::HEX
  WALLPAPERS = %w[glow mesh solid none].freeze
  WALLPAPER_LABELS = LocalizedLabel.for("appearance.wallpapers", WALLPAPERS)
  # Só fontes do sistema ou já servidas pela suíte (nada baixado de fora).
  FONTS = { "manrope" => %("Manrope", system-ui, sans-serif), "system" => %(system-ui, -apple-system, "Segoe UI", Roboto, sans-serif),
            "rounded" => %(ui-rounded, "SF Pro Rounded", "Nunito", system-ui, sans-serif), "serif" => %(ui-serif, Georgia, "Times New Roman", serif),
            "mono" => %("DM Mono", ui-monospace, monospace) }.freeze
  FONT_LABELS = LocalizedLabel.for("appearance.fonts", FONTS.keys)
  MAX = 30

  validates :name, presence: true, length: { maximum: 40 }
  validates :key, presence: true, uniqueness: { scope: :tenant_id }, format: { with: /\Au-[a-z0-9]{4,12}\z/ }
  validates :accent, :accent2, format: { with: HEX }
  validates :wall_style, inclusion: { in: WALLPAPERS }
  validates :font, inclusion: { in: FONTS.keys }
  validate :limit, on: :create

  normalizes :name, with: ->(v) { v.to_s.squish }
  normalizes :accent, :accent2, with: ->(v) { v.to_s.strip.downcase }
  before_validation { self.key ||= "u-#{SecureRandom.alphanumeric(8).downcase}" }

  def label = name
  def wallpaper = wallpaper_css

  # Papel de parede em CSS a partir das duas cores (só cores validadas).
  def wallpaper_css
    a = rgba(accent, 0.32)
    b = rgba(accent2, 0.28)
    case wall_style
    when "glow" then "radial-gradient(60% 50% at 10% 0%, #{a}, transparent), radial-gradient(55% 55% at 95% 95%, #{b}, transparent)"
    when "mesh" then "radial-gradient(40% 40% at 20% 20%, #{a}, transparent), radial-gradient(45% 45% at 80% 30%, #{b}, transparent), " \
                     "radial-gradient(50% 50% at 50% 100%, #{rgba(accent, 0.22)}, transparent)"
    when "solid" then "linear-gradient(#{rgba(accent, 0.12)}, #{rgba(accent2, 0.12)})"
    end
  end

  def css = [ Dashboards::Themes.css_vars(accent, accent2, wallpaper), ("--font-sans: #{FONTS.fetch(font)}" if font != "manrope") ].compact.join("; ")

  private

  def rgba(hex, alpha) = "rgba(#{hex[1..].scan(/../).map { |x| x.to_i(16) }.join(', ')}, #{alpha})"

  def limit
    errors.add(:base, I18n.t("appearance.too_many", max: MAX)) if DashboardTheme.count >= MAX
  end
end
