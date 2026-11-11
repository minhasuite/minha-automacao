import { Controller } from "@hotwired/stimulus"

// Editor de JSON do widget (P1.5): tocar numa prop do tipo põe `"chave": ` no
// cursor do texto (o resto da validação é do servidor).
export default class extends Controller {
  static targets = ["text"]

  insert(event) {
    const area = this.textTarget
    const text = `"${event.params.key}": `
    const { selectionStart: a, selectionEnd: b, value } = area
    area.value = value.slice(0, a) + text + value.slice(b)
    area.focus()
    area.setSelectionRange(a + text.length, a + text.length)
  }
}
