// Lambda da skill Smart Home da Minha Automação (Node.js 20+).
// Só repassa a diretiva da Alexa para o servidor da casa, que faz tudo
// (descoberta, estado, comandos). O token do account linking já vai dentro
// da diretiva; ele também segue no cabeçalho Authorization.
// Passo a passo: docs/alexa-skill.md.
const URL = process.env.MA_URL || "https://casa-automacao.minhasuite.com/alexa/smart_home";

export const handler = async (event) => {
  const d = event.directive || {};
  const token = d.endpoint?.scope?.token || d.payload?.scope?.token || d.payload?.grantee?.token || "";
  try {
    const res = await fetch(URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(event),
      signal: AbortSignal.timeout(7000),
    });
    return await res.json();
  } catch (e) {
    console.log("Servidor da casa fora do ar:", e.message);
    return {
      event: {
        header: { namespace: "Alexa", name: "ErrorResponse", payloadVersion: "3", messageId: crypto.randomUUID(), correlationToken: d.header?.correlationToken },
        endpoint: d.endpoint,
        payload: { type: "ENDPOINT_UNREACHABLE", message: "Servidor da casa fora do ar." },
      },
    };
  }
};
