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
// renderizado com o papel de quem vê. Junta avisos seguidos em 250 ms.
const stale = new Set()
let staleTimer
Turbo.StreamActions.point_changed = function () {
  document.dispatchEvent(new CustomEvent("dw:point-changed", { detail: this.target })) // quiosque: acordar no movimento
  document.querySelectorAll(`turbo-frame[data-points~="${CSS.escape(this.target)}"]`).forEach((f) => stale.add(f))
  clearTimeout(staleTimer)
  staleTimer = setTimeout(() => {
    stale.forEach((f) => {
      if (!f.isConnected) return
      if (f.getAttribute("src")) f.reload(); else f.src = f.dataset.src
    })
    stale.clear()
  }, 250)
}

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

// Menus em <details> (.ss-menu da gem e .dw-pop): Esc fecha e devolve o
// foco ao botão, clique fora fecha, e o summary diz se está aberto (aria-expanded).
const MENUS = "details.ss-menu, details.dw-pop"
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
