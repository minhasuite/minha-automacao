// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

// Confirmação (data-turbo-confirm) no <dialog> da suíte, não no confirm() do navegador.
// O botão leva o verbo da ação (data-turbo-confirm-button="Arquivar" no botão ou no
// form; sem ele, o verbo do começo da pergunta: "Remover a fase?" → Remover) e fica
// vermelho quando a ação destrói ou desfaz algo. Título: data-turbo-confirm-title.
const DANGER = /^(apagar|arquivar|cancelar|desconectar|encerrar|excluir|recusar|remover|tirar|zerar)/i
Turbo.config.forms.confirm = (message, element, submitter) => {
  const dialog = document.getElementById("confirm")
  if (!dialog) return Promise.resolve(confirm(message))
  const data = { ...element?.dataset, ...submitter?.dataset }
  const first = message.match(DANGER)?.[0]
  const verb = data.turboConfirmButton || (first ? first[0].toUpperCase() + first.slice(1).toLowerCase() : "Confirmar")
  const ok = dialog.querySelector("[value=ok]")
  dialog.querySelector("[data-title]").textContent = data.turboConfirmTitle || "Tem certeza?"
  dialog.querySelector("[data-message]").textContent = message
  ok.textContent = verb
  ok.classList.toggle("ss-btn-danger", DANGER.test(verb) || DANGER.test(message))
  ok.classList.toggle("ss-btn-primary", !ok.classList.contains("ss-btn-danger"))
  dialog.showModal()
  return new Promise((resolve) => dialog.addEventListener("close", () => resolve(dialog.returnValue === "ok"), { once: true }))
}

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

// Máscaras (data-mask): o servidor guarda só os dígitos de documento/telefone/CEP;
// dinheiro se formata ao sair do campo ("1234,5" → "1.234,50").
const masks = {
  document: (d) => d.length <= 11
    ? d.replace(/(\d{3})(\d)/, "$1.$2").replace(/(\d{3})(\d)/, "$1.$2").replace(/(\d{3})(\d{1,2})$/, "$1-$2")
    : d.slice(0, 14).replace(/^(\d{2})(\d)/, "$1.$2").replace(/^(\d{2})\.(\d{3})(\d)/, "$1.$2.$3").replace(/\.(\d{3})(\d)/, ".$1/$2").replace(/(\d{4})(\d)/, "$1-$2"),
  phone: (d) => d.slice(0, 11).replace(/^(\d{2})(\d)/, "($1) $2").replace(/(\d)(\d{4})$/, "$1-$2"),
  cep: (d) => d.slice(0, 8).replace(/^(\d{5})(\d)/, "$1-$2")
}
const applyMask = (input) => {
  const fn = masks[input.dataset.mask]
  if (fn && input.value) input.value = fn(input.value.replace(/\D/g, ""))
}
document.addEventListener("input", (e) => { if (e.target.dataset?.mask && e.target.dataset.mask !== "money") applyMask(e.target) })
document.addEventListener("focusout", (e) => {
  if (e.target.dataset?.mask !== "money" || !e.target.value.trim()) return
  const n = parseFloat(e.target.value.replace(/[^\d,.-]/g, "").replace(/\./g, "").replace(",", "."))
  if (!isNaN(n)) e.target.value = n.toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
})
document.addEventListener("turbo:load", () => document.querySelectorAll("[data-mask]:not([data-mask=money])").forEach(applyMask))

// PWA (Lote 1): o service worker recebe o push e responde os botões do aviso.
// Só em contexto seguro (https ou localhost): pelo http da rede de casa não registra.
if ("serviceWorker" in navigator && window.isSecureContext) {
  navigator.serviceWorker.register("/service-worker.js", { scope: "/" }).catch(() => {})
}
