// Onde a página está rodando (pwa-ios, docs/pwa.md): app instalado (standalone), iPhone/iPad, Safari.
// O iPad novo se diz "Macintosh": é o toque que entrega.
export function standalone() {
  return window.matchMedia?.("(display-mode: standalone)").matches || window.matchMedia?.("(display-mode: fullscreen)").matches || navigator.standalone === true
}

export function ios() {
  const ua = navigator.userAgent
  return /iPad|iPhone|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)
}

// Safari do iPhone (Chrome, Firefox e Edge do iPhone têm a marca própria no user agent).
export function iosSafari() {
  return ios() && !/CriOS|FxiOS|EdgiOS|OPiOS/.test(navigator.userAgent)
}

// Pedido de instalação do Chrome/Edge (Android e computador): guardado em application.js no evento
// beforeinstallprompt, que chega uma vez só, às vezes antes dos controllers.
export function installPrompt() { return window.maInstallPrompt || null }
