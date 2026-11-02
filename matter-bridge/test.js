// Prova da ponte sem rede nem pareamento: cada tipo do Rails vira endpoint
// do matter.js, o estado do MA não volta como comando (eco) e a mudança
// vinda do ecossistema volta. `node --test` (ver package.json).
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

process.env.MATTER_STORAGE_PATH = mkdtempSync(join(tmpdir(), "ma-bridge-"));
const { Bridge, TYPES, createServer, status } = await import("./index.js");

const fixture = JSON.parse(await (await import("node:fs/promises")).readFile(new URL("./fixture.json", import.meta.url)));

test("todos os tipos sobem, eco não volta e mudança de fora vira comando", async (t) => {
  const { server, aggregator } = await createServer();
  t.after(() => server.close());
  const sent = [];
  const bridge = new Bridge(server, aggregator, async (...a) => sent.push(a));
  await bridge.sync(fixture.devices);
  assert.deepEqual([...new Set(fixture.devices.map((d) => d.type))].sort(), Object.keys(TYPES).sort());
  assert.equal(bridge.endpoints.size, fixture.devices.length);

  const light = fixture.devices.find((d) => d.type === "on_off_light");
  const cur = bridge.endpoints.get(light.id);
  await bridge.sync(fixture.devices.map((d) => (d.id === light.id ? { ...d, state: { onOff: { onOff: true } } } : d)));
  assert.equal(cur.ep.state.onOff.onOff, true);
  assert.deepEqual(sent, []);

  await cur.ep.set({ onOff: { onOff: false } }); // como se o Apple Casa desligasse
  assert.deepEqual(sent, [[light.id, "onOff.onOff", false]]);

  await bridge.sync(fixture.devices.filter((d) => d.id !== light.id));
  assert.equal(bridge.endpoints.has(light.id), false);

  const s = status(server);
  assert.match(s.qr, /^MT:/);
  assert.match(s.manual, /^\d{11}$/);
  assert.equal(s.commissioned, false);
});
