// Prova da ponte HomeKit sem rede nem pareamento: cada tipo do Rails vira
// acessório do hap-nodejs, o estado do MA não volta como comando (eco) e a
// mudança vinda do app Casa volta. `node --test` (ver package.json).
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

process.env.HAP_STORAGE_PATH = mkdtempSync(join(tmpdir(), "ma-homekit-"));
const { Bridge, TYPES, createBridge, identity, status } = await import("./index.js");
const hap = (await import("hap-nodejs")).default;

const fixture = JSON.parse(await (await import("node:fs/promises")).readFile(new URL("./fixture.json", import.meta.url)));

test("todos os tipos sobem, eco não volta e mudança de fora vira comando", async () => {
  const hapBridge = createBridge();
  const sent = [];
  const bridge = new Bridge(hapBridge, async (...a) => sent.push(a));
  bridge.sync(fixture.devices);
  assert.deepEqual([...new Set(fixture.devices.map((d) => d.type))].sort(), Object.keys(TYPES).sort());
  assert.equal(bridge.accessories.size, fixture.devices.length);
  assert.equal(hapBridge.bridgedAccessories.length, fixture.devices.length);

  const gate = fixture.devices.find((d) => d.type === "garage_door");
  const cur = bridge.accessories.get(gate.id);
  const target = cur.service.getCharacteristic(hap.Characteristic.TargetDoorState);
  assert.equal(target.value, 1);
  bridge.sync(fixture.devices.map((d) => (d.id === gate.id ? { ...d, state: { GarageDoorOpener: { CurrentDoorState: 0, TargetDoorState: 0, ObstructionDetected: false } } } : d)));
  assert.equal(target.value, 0);
  assert.deepEqual(sent, []); // estado vindo do MA não volta

  await target.handleSetRequest(1); // como se o app Casa mandasse fechar
  assert.deepEqual(sent, [[gate.id, "GarageDoorOpener.TargetDoorState", 1]]);

  const temp = bridge.accessories.get(fixture.devices.find((d) => d.type === "temperature_sensor").id);
  assert.equal(temp.service.getCharacteristic(hap.Characteristic.CurrentTemperature).value, 26.5);

  bridge.sync(fixture.devices.filter((d) => d.id !== gate.id));
  assert.equal(bridge.accessories.has(gate.id), false);
});

test("identidade com PIN válido do HAP, guardada, e URI de pareamento", () => {
  const dir = mkdtempSync(join(tmpdir(), "ma-homekit-id-"));
  const id = identity(dir);
  assert.match(id.pincode, /^\d{3}-\d{2}-\d{3}$/);
  assert.match(id.username, /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/);
  assert.deepEqual(identity(dir), id);
  const hapBridge = createBridge();
  hapBridge._setupID = id.setupID; // o publish() faz isso; aqui sem rede
  hapBridge._accessoryInfo = { pincode: id.pincode, setupID: id.setupID, category: hap.Categories.BRIDGE };
  const s = status(hapBridge, id, false);
  assert.match(s.qr, /^X-HM:\/\//);
  assert.equal(s.commissioned, false);
});
