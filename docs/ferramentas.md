# Ferramentas de desenvolvedor (Pacote 3)

As "Ferramentas de desenvolvedor" do HA, por local: Local → **Ferramentas**
(`/locais/:id/ferramentas`). Só administrador ou dono da instalação (membro
recebe 404; a aba nem aparece). Serviço comum: `DevTools`.

| Aba | Faz | API |
| --- | --- | --- |
| Estados | Pontos com filtro (nome, chave, valor, tipo), valor, situação e atributos. **Definir valor só de helper**, pela regra do tipo (`plugin.check`; o painel de alarme recusa). | `GET /sites/:id/dev/states`, `POST /sites/:id/dev/states/:point_id` |
| Modelo | Liquid ou expressão com o contexto do local, ao vivo enquanto digita (Stimulus `live-form` → Turbo Frame). | `POST /sites/:id/dev/template` |
| Ação | Comando num ponto com confirmação. Caminho normal (`Points::Command`, papel x risco) e **respeita a sombra** do local (`Shadow.for_site`). | `POST /points/:id/commands` |
| Eventos | Disparar (nome + JSON) e escutar: cada `Automations::Triggers.event` do local aparece na hora (`DevTools.broadcast`, Turbo Stream assinado). Nome do sistema não vale. | `POST /sites/:id/dev/events` |

Nada aqui tira algo da sombra nem fala com aparelho por fora do caminho
normal dos comandos.
