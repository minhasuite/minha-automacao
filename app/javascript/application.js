// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

// "Processando" também nos formulários fora do Turbo (data-turbo=false: upload
// e telas da IA que respondem com página): o Turbo só cuida dos dele.
document.addEventListener("submit", (e) => {
  const b = e.submitter
  if (!b?.dataset.turboSubmitsWith || !(b.dataset.turbo === "false" || e.target.closest("[data-turbo=false]"))) return
  setTimeout(() => {
    b.disabled = true
    if (b.tagName === "INPUT") b.value = b.dataset.turboSubmitsWith; else b.textContent = b.dataset.turboSubmitsWith
  })
})

// Âncora para uma seção recolhida (<details id>, ex. a fase salva no editor) abre a seção.
document.addEventListener("turbo:load", () => {
  const el = location.hash.length > 1 && document.getElementById(decodeURIComponent(location.hash.slice(1)))
  const d = el && (el.tagName === "DETAILS" ? el : el.closest("details"))
  if (d) { d.open = true; el.scrollIntoView({ block: "start" }) }
})

// Dashboards: o servidor avisa "o ponto X mudou" (stream do local, sem HTML) e
// cada quadro de widget que depende dele (data-points) se recarrega sozinho,
// renderizado com o papel de quem vê. Junta avisos seguidos em 250 ms, mas nunca
// segura mais que 1 s (medição mudando sem parar não pode travar a tela), recarrega
// cada quadro uma vez só e, com a aba escondida, guarda para quando ela voltar.
const stale = new Set()
let staleTimer, staleSince = 0
const flushStale = () => {
  clearTimeout(staleTimer)
  staleTimer = null
  staleSince = 0
  if (document.hidden) return
  stale.forEach((f) => {
    if (!f.isConnected) return
    if (f.getAttribute("src")) f.reload(); else f.src = f.dataset.src
  })
  stale.clear()
}
Turbo.StreamActions.point_changed = function () {
  document.dispatchEvent(new CustomEvent("dw:point-changed", { detail: this.target })) // quiosque: acordar no movimento
  document.querySelectorAll(`turbo-frame[data-points~="${CSS.escape(this.target)}"]`).forEach((f) => stale.add(f))
  if (!stale.size || document.hidden) return
  const now = Date.now()
  staleSince ||= now
  clearTimeout(staleTimer)
  staleTimer = setTimeout(flushStale, Math.max(0, Math.min(250, staleSince + 1000 - now)))
}
document.addEventListener("visibilitychange", () => { if (!document.hidden && stale.size) flushStale() })

// Comando de ponto (POST /pontos/:id/comando): o aparelho leva segundos, então a tela
// responde no toque. A chave (ss-switch) já vira sozinha; aqui o tile de aperto (portão,
// script, cena) entra em "Enviando…" (o anel da gem) e o botão de comando gira
// (.ss-action-btn.is-loading da gem). Falhou: tile em erro, botão volta.
const COMMAND_FORM = 'form[action$="/comando"]'
// A chave do tile (o ícone, componentes_ui v0.12, form com ss-switch) cuida do próprio "Enviando…".
const sendingTile = (form) => (!form.matches('[data-controller~="ss-switch"]') && form.closest(".ss-device")) || null
document.addEventListener("turbo:submit-start", (e) => {
  const form = e.target
  if (!form.matches?.(COMMAND_FORM)) return
  const tile = sendingTile(form)
  if (tile) {
    tile.dataset.maWas = tile.dataset.status || "ready"
    tile.dataset.status = "pending"
    tile.dataset.maSending = "1"
    tile.setAttribute("aria-busy", "true")
    return
  }
  const b = e.detail?.formSubmission?.submitter
  if (b?.classList.contains("ss-btn")) b.classList.add("ss-action-btn", "is-loading")
})
document.addEventListener("turbo:submit-end", (e) => {
  const form = e.target
  if (!form.matches?.(COMMAND_FORM)) return
  const ok = e.detail?.success !== false
  const frame = form.closest("turbo-frame")
  if (frame) frame.maChecks = 0 // comando novo: conta de novo as conferências
  const tile = sendingTile(form)
  if (tile?.dataset.maSending) {
    delete tile.dataset.maSending
    tile.removeAttribute("aria-busy")
    tile.dataset.status = ok ? tile.dataset.maWas : "error"
    if (!ok) { const st = tile.querySelector(".ss-device-state"); if (st?.dataset.error) st.textContent = st.dataset.error }
  }
  const b = e.detail?.formSubmission?.submitter
  if (b?.classList.contains("is-loading")) {
    b.classList.remove("is-loading")
    if (ok && b.isConnected) { b.classList.add("is-done"); setTimeout(() => b.classList.remove("is-done", "ss-action-btn"), 1200) }
  }
})

// Tile que veio do servidor "Enviando…" (comando ainda sem resposta do aparelho, Points::Inflight):
// confere de novo a cada 4 s, no máximo até o comando expirar, caso o aviso do aparelho não chegue.
const recheckPending = () => {
  document.querySelectorAll('.ss-device[data-status="pending"]:not([data-ma-sending])').forEach((tile) => {
    const f = tile.closest("turbo-frame")
    if (!f || f.maRecheck || (f.maChecks || 0) >= 15) return
    f.maChecks = (f.maChecks || 0) + 1
    f.maRecheck = setTimeout(() => {
      f.maRecheck = null
      if (!f.isConnected || document.hidden) return
      if (f.getAttribute("src")) f.reload(); else f.src = f.dataset.src || location.href
    }, 4000)
  })
}
document.addEventListener("turbo:load", recheckPending)
document.addEventListener("turbo:frame-render", recheckPending)

// Slider e seleção de widget se aplicam ao soltar/escolher.
document.addEventListener("change", (e) => {
  if (e.target.matches("[data-autosubmit]")) e.target.form.requestSubmit()
})

// −/+ da gem (Ss::StepperInputComponent) num form de comando de widget
// (form[data-dw-autosubmit]): vários toques seguidos viram um comando só.
document.addEventListener("change", (e) => {
  const form = e.target.closest?.("form[data-dw-autosubmit]")
  if (!form) return
  clearTimeout(form.dwTimer)
  form.dwTimer = setTimeout(() => form.requestSubmit(), 600)
})

// O título da câmera e as ações do aviso da gem não aceitam data-turbo-frame (o tile
// usa link_data:): dentro do quadro de um widget abrem a página toda.
const TOP_IN_WIDGET = "turbo-frame :is(.ss-cam a.ss-cam-title, .ss-notice :is(a[href], button[type=submit])):not([data-turbo-frame])"
document.addEventListener("click", (e) => {
  const el = e.target.closest?.(TOP_IN_WIDGET)
  if (el) el.dataset.turboFrame = "_top"
}, true)

// Linha de tabela inteira clicável: vai para o primeiro link da linha.
document.addEventListener("click", (e) => {
  const row = e.target.closest(".ss-table tbody tr")
  if (!row || e.target.closest("a, button, input, select, label, textarea, form") || getSelection().toString()) return
  const link = row.querySelector("a[href]")
  if (link) e.metaKey || e.ctrlKey ? window.open(link.href) : link.click()
})

// Filtros (.ss-filters) se aplicam sozinhos ao mudar um campo; o botão "Filtrar" fica escondido.
document.addEventListener("change", (e) => {
  const form = e.target.closest("form.ss-filters")
  if (form) form.requestSubmit()
})

// PWA (Lote 1): o service worker recebe o push e responde os botões do aviso.
// Só em contexto seguro (https ou localhost): pelo http da rede de casa não registra.
if ("serviceWorker" in navigator && window.isSecureContext) {
  navigator.serviceWorker.register("/service-worker.js", { scope: "/" }).catch(() => {})
}

// Instalar (pwa-ios, docs/pwa.md): o Chrome/Edge entrega o pedido de instalação uma vez; guarda para o
// botão "Instalar o app" (pwa-install). O iPhone não tem esse evento: lá é o passo a passo.
window.addEventListener("beforeinstallprompt", (e) => {
  e.preventDefault()
  window.maInstallPrompt = e
  window.dispatchEvent(new Event("ma:installable"))
})
window.addEventListener("appinstalled", () => { window.maInstallPrompt = null })

// Selo do ícone do app instalado (Badging API: iPhone na Tela de Início 16.4+, Chrome/Edge instalado) com os
// avisos não lidos do <meta name="ma-unread"> do layout; o service worker acerta o número quando chega push.
function appBadge() {
  const meta = document.querySelector('meta[name="ma-unread"]')
  if (!meta || !("setAppBadge" in navigator)) return
  const n = parseInt(meta.content, 10) || 0
  ;(n > 0 ? navigator.setAppBadge(n) : navigator.clearAppBadge()).catch(() => {})
}
document.addEventListener("turbo:load", appBadge)
document.addEventListener("turbo:morph", appBadge)

// Menus em <details> (.ss-menu da gem e o .ma-kiosk-pop do quiosque): Esc fecha e devolve o
// foco ao botão, clique fora fecha, e o summary diz se está aberto (aria-expanded).
const MENUS = "details.ss-menu, details.ma-kiosk-pop"
document.addEventListener("toggle", (e) => {
  if (e.target.matches?.(MENUS)) e.target.querySelector(":scope > summary")?.setAttribute("aria-expanded", e.target.open)
}, true)
document.addEventListener("turbo:load", () => document.querySelectorAll(MENUS).forEach((d) => d.querySelector(":scope > summary")?.setAttribute("aria-expanded", d.open)))
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const d = document.activeElement?.closest(`${MENUS}[open]`) || document.querySelector(`${MENUS}[open]`)
  if (!d) return
  d.open = false
  d.querySelector(":scope > summary")?.focus()
})
document.addEventListener("click", (e) => {
  document.querySelectorAll(`${MENUS}[open]`).forEach((d) => { if (!d.contains(e.target)) d.open = false })
})
