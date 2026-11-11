import { Controller } from "@hotwired/stimulus"

// Atalhos do editor de painel (ideia 7). O widget escolhido é o último clicado
// ou focado ([data-dw-widget] na lista do editor, .dw-ed-w[data-id] no layout ao
// vivo) e ganha .dw-ed-picked. As ações enviam os formulários do próprio editor
// (op do rascunho, copiar) ou clicam nos botões marcados [data-dw-key] (desfazer,
// refazer); fora de campo de texto e sem texto selecionado.
export default class extends Controller {
  static targets = ["form", "copy"]
  static values = { remove: String, removeButton: String }

  pick(event) {
    const el = event.target.closest?.("[data-dw-widget], .dw-ed-w[data-id]")
    if (!el) return
    this.picked = el.dataset.dwWidget || el.dataset.id
    document.querySelectorAll(".dw-ed-picked").forEach((x) => x.classList.remove("dw-ed-picked"))
    el.classList.add("dw-ed-picked")
  }

  key(event) {
    if (this.typing(event)) return
    const mod = event.ctrlKey || event.metaKey
    const k = event.key.toLowerCase()
    if (mod && k === "z") return this.press(event, event.shiftKey ? "redo" : "undo")
    if (mod && k === "y") return this.press(event, "redo")
    if (event.key === "Escape" && this.picked) return this.unpick()
    if (!this.picked) return
    if (mod && k === "c" && !String(getSelection())) return this.send(event, this.copyTarget)
    if (mod && k === "d") return this.op(event, "duplicate", this.picked)
    if (mod && k === "v") return this.op(event, "paste", this.sectionOf(this.picked))
    if (!mod && (event.key === "Delete" || event.key === "Backspace")) return this.op(event, "remove", this.picked, true)
    if (!mod && event.key === "Enter" && !event.target.closest("a, button, summary")) return this.edit(event)
  }

  typing(event) {
    const t = event.target
    return t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName) || document.querySelector("dialog[open]")
  }

  press(event, key) {
    const button = document.querySelector(`[data-dw-key="${key}"] button:not([disabled]), button[data-dw-key="${key}"]:not([disabled])`)
    if (!button) return
    event.preventDefault()
    button.click()
  }

  op(event, op, target, confirm = false) {
    if (!target) return
    event.preventDefault()
    const form = this.formTarget
    form.querySelector("[name=op]").value = op
    form.querySelector("[name=target]").value = target
    if (confirm) {
      form.dataset.turboConfirm = this.removeValue
      form.dataset.turboConfirmTone = "danger"
      form.dataset.turboConfirmButton = this.removeButtonValue
    } else {
      delete form.dataset.turboConfirm
    }
    form.requestSubmit()
  }

  send(event, form) {
    event.preventDefault()
    form.querySelector("[name=target]").value = this.picked
    form.requestSubmit()
  }

  // Colar vai para a seção do widget escolhido (a do layout ao vivo ou a do cartão da lista).
  sectionOf(id) {
    const live = document.querySelector(`.dw-ed-w[data-id="${CSS.escape(id)}"]`)?.closest("[data-section]")
    return live?.dataset.section || document.querySelector(`[data-dw-widget="${CSS.escape(id)}"]`)?.closest("[data-dw-section]")?.dataset.dwSection
  }

  edit(event) {
    const link = document.querySelector(`.dw-ed-w[data-id="${CSS.escape(this.picked)}"] .dw-ed-edit`)
    const summary = document.querySelector(`[data-dw-widget="${CSS.escape(this.picked)}"] summary`)
    if (!link && !summary) return
    event.preventDefault()
    ;(link || summary).click()
  }

  unpick() {
    this.picked = null
    document.querySelectorAll(".dw-ed-picked").forEach((x) => x.classList.remove("dw-ed-picked"))
  }
}
