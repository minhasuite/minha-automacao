module OnboardingHelper
  # QR em SVG (rqrcode, só o texto dado; nada de fora entra no SVG).
  def qr_svg(text)
    RQRCode::QRCode.new(text.to_s).as_svg(module_size: 4, standalone: true, use_path: true, viewbox: true, color: "1e1a38").html_safe # rubocop:disable Rails/OutputSafety
  end
end
