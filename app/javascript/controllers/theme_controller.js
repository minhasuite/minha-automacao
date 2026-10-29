import { Controller } from "@hotwired/stimulus"

// Tema escolhido pelo usuário (claro/escuro) sobrepõe o do sistema. Só
// preferência deste navegador: se o localStorage falhar, segue o sistema.
export default class extends Controller {
  connect() {
    try {
      const saved = localStorage.getItem("theme")
      if (saved) document.documentElement.dataset.theme = saved
    } catch (_) {}
  }

  // Botão "Tema" do menu: alterna claro/escuro a partir do que está na tela.
  toggle() {
    const dark = document.documentElement.dataset.theme === "dark" ||
      (!document.documentElement.dataset.theme && matchMedia("(prefers-color-scheme: dark)").matches)
    this.set({ params: { theme: dark ? "light" : "dark" } })
  }

  set(event) {
    const theme = event.params.theme
    if (theme === "system") delete document.documentElement.dataset.theme
    else document.documentElement.dataset.theme = theme
    try { theme === "system" ? localStorage.removeItem("theme") : localStorage.setItem("theme", theme) } catch (_) {}
  }
}
