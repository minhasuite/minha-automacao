// Ponte HomeKit do Minha Automação (ondaC1, C5): HAP nativo (hap-nodejs),
// para o app Casa da Apple em iPhones/iPads/HomePods sem Matter e para tipos
// que o Matter ainda não leva (portão de garagem com estado de verdade).
//
// A cada POLL_S lê GET /api/v1/bridges/homekit ({id, type, name, state, listen});
// `state` já vem no formato do HAP ({Serviço: {Característica: valor}}). O que
// o Casa muda nas características de `listen` volta como
// POST /api/v1/bridges/homekit/commands. A situação (URI de pareamento, PIN,
// pareada?) vai em PUT /api/v1/bridges/homekit/status. A tradução fica toda
// no Rails (Bridges::HomekitBridge); aqui só o tipo → serviço do HAP.
//
// Ambiente: MA_URL, MA_API_KEY (chave gerada na tela da ponte), POLL_S (3),
// HAP_PORT (51826), HAP_STORAGE_PATH (pareamento; /data no compose).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes, randomInt } from "node:crypto";
import { join } from "node:path";
import hap from "hap-nodejs";

const { Accessory, Bridge: HapBridge, Categories, Characteristic, HAPStorage, Service, uuid, AccessoryEventTypes } = hap;
const MA_URL = (process.env.MA_URL || "http://127.0.0.1").replace(/\/$/, "");
const KEY = process.env.MA_API_KEY;
const POLL_MS = Number(process.env.POLL_S || 3) * 1000;
const STORAGE = process.env.HAP_STORAGE_PATH || "/data";

// Tipo do Rails → serviço do HAP e a categoria do acessório.
export const TYPES = {
  garage_door: ["GarageDoorOpener", Categories.GARAGE_DOOR_OPENER],
  window_covering: ["WindowCovering", Categories.WINDOW_COVERING],
  thermostat: ["Thermostat", Categories.THERMOSTAT],
  color_light: ["Lightbulb", Categories.LIGHTBULB],
  dimmable_light: ["Lightbulb", Categories.LIGHTBULB],
  light: ["Lightbulb", Categories.LIGHTBULB],
  switch: ["Switch", Categories.SWITCH],
  contact_sensor: ["ContactSensor", Categories.SENSOR],
  motion_sensor: ["MotionSensor", Categories.SENSOR],
  temperature_sensor: ["TemperatureSensor", Categories.SENSOR],
  humidity_sensor: ["HumiditySensor", Categories.SENSOR],
};

const log = (...a) => console.log(new Date().toISOString(), ...a);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

async function api(method, path, body) {
  const res = await fetch(`${MA_URL}/api/v1/bridges/homekit${path}`, {
    method, headers: { "X-Api-Key": KEY, "Content-Type": "application/json", Accept: "application/json" },
    body: body && JSON.stringify(body), signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok && res.status !== 204) throw new Error(`MA ${method} ${path}: ${res.status}`);
  return res.status === 204 ? null : res.json();
}

// Identidade da ponte (MAC de mentira e PIN aleatório), criada uma vez e guardada.
export function identity(dir = STORAGE) {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "ma-homekit.json");
  try { return JSON.parse(readFileSync(file, "utf8")); } catch { /* primeira vez */ }
  const mac = [...randomBytes(6)].map((b, i) => (i === 0 ? (b | 0x02) & 0xfe : b).toString(16).padStart(2, "0")).join(":").toUpperCase();
  const d = () => String(randomInt(0, 10));
  let pin = Array.from({ length: 8 }, d).join("");
  while (/^(\d)\1+$|^12345678$|^87654321$/.test(pin)) pin = Array.from({ length: 8 }, d).join(""); // códigos que o HAP proíbe
  const id = { username: mac, pincode: `${pin.slice(0, 3)}-${pin.slice(3, 5)}-${pin.slice(5)}`, setupID: randomBytes(2).toString("hex").toUpperCase() };
  writeFileSync(file, JSON.stringify(id));
  return id;
}

export class Bridge {
  constructor(hapBridge, send) {
    this.hap = hapBridge;
    this.send = send; // (id, "Serviço.Característica", valor) → comando no MA
    this.accessories = new Map(); // id → {acc, service, type, name, state, applied}
  }

  // Lista do MA → acessórios (cria, atualiza, tira). Não comanda nada no MA.
  sync(devices) {
    const seen = new Set();
    for (const d of devices) {
      if (!TYPES[d.type]) continue;
      seen.add(d.id);
      let cur = this.accessories.get(d.id);
      if (cur && (cur.type !== d.type || cur.name !== d.name)) { this.remove(d.id); cur = null; }
      if (!cur) cur = this.add(d);
      if (!same(cur.state, d.state)) this.apply(cur, d.state);
    }
    for (const id of [...this.accessories.keys()]) if (!seen.has(id)) this.remove(id);
  }

  add(d) {
    const [serviceName, category] = TYPES[d.type];
    const acc = new Accessory(d.name.slice(0, 64), uuid.generate(`ma:${d.id}`));
    acc.category = category;
    acc.getService(Service.AccessoryInformation)
      .setCharacteristic(Characteristic.Manufacturer, (d.manufacturer || "Minha Automação").slice(0, 64))
      .setCharacteristic(Characteristic.Model, d.type)
      .setCharacteristic(Characteristic.SerialNumber, String(d.id).slice(0, 64));
    const service = acc.addService(Service[serviceName], d.name.slice(0, 64));
    const cur = { acc, service, type: d.type, name: d.name, state: {}, applied: {} };
    for (const path of d.listen || []) {
      const [, char] = path.split(".");
      service.getCharacteristic(Characteristic[char]).onSet(async (value) => {
        if (same(value, cur.applied[path])) return; // eco do que veio do MA
        cur.applied[path] = value;
        await this.send(d.id, path, value);
      });
    }
    this.hap.addBridgedAccessory(acc);
    this.accessories.set(d.id, cur);
    log("exposto:", d.type, d.name);
    return cur;
  }

  apply(cur, state) {
    for (const [, chars] of Object.entries(state || {})) {
      for (const [char, value] of Object.entries(chars)) {
        if (value === null || value === undefined || !Characteristic[char]) continue;
        for (const path of Object.keys(cur.applied)) if (path.endsWith(`.${char}`)) cur.applied[path] = value;
        cur.service.getCharacteristic(Characteristic[char]).updateValue(value);
      }
    }
    cur.state = state;
  }

  remove(id) {
    const cur = this.accessories.get(id);
    this.accessories.delete(id);
    if (cur) this.hap.removeBridgedAccessory(cur.acc);
    log("removido:", cur?.name);
  }
}

export function createBridge() {
  HAPStorage.setCustomStoragePath(STORAGE);
  return new HapBridge("Minha Automação", uuid.generate("ma:homekit-bridge"));
}

export function status(hapBridge, id, paired) {
  return { qr: hapBridge.setupURI(), manual: id.pincode, commissioned: paired, fabrics: paired ? 1 : 0, port: Number(process.env.HAP_PORT || 51826) };
}

async function main() {
  if (!KEY) throw new Error("Falta MA_API_KEY (gere na tela Ponte HomeKit do local).");
  const id = identity();
  const hapBridge = createBridge();
  let paired = false;
  hapBridge.on(AccessoryEventTypes.PAIRED, () => { paired = true; });
  hapBridge.on(AccessoryEventTypes.UNPAIRED, () => { paired = false; });
  const bridge = new Bridge(hapBridge, (pointId, attribute, value) => api("POST", "/commands", { point_id: pointId, attribute, value }));
  await hapBridge.publish({ username: id.username, pincode: id.pincode, setupID: id.setupID, port: Number(process.env.HAP_PORT || 51826), category: Categories.BRIDGE });
  paired = hapBridge._accessoryInfo?.paired?.() === true;
  log("ponte HomeKit no ar");
  for (;;) {
    try {
      const { data } = await api("GET", "");
      bridge.sync(data.devices);
      await api("PUT", "/status", status(hapBridge, id, paired));
    } catch (e) {
      log("sem o MA:", e.message);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
