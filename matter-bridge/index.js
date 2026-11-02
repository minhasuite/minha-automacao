// Ponte Matter do Minha Automação (integ). Publica os pontos expostos na tela
// "Ponte Matter" como aparelhos de uma ponte Matter (matter.js), para Apple
// Casa/Siri, Google Home e Alexa comandarem pela rede de casa.
//
// A cada POLL_S lê GET /api/v1/bridges/matter ({id, type, name, state, listen});
// `state` já vem no formato do matter.js ({cluster: {atributo: valor}}). O que
// o ecossistema muda nos atributos de `listen` volta como
// POST /api/v1/bridges/matter/commands. A situação (QR, código, pareada?) vai
// em PUT /api/v1/bridges/matter/status. A tradução fica toda no Rails
// (Bridges::MatterBridge); aqui só o tipo → classe do matter.js.
//
// Ambiente: MA_URL (ex.: http://127.0.0.1:80), MA_API_KEY (chave gerada na
// tela), POLL_S (padrão 3), MATTER_PORT (5540), PASSCODE/DISCRIMINATOR
// (opcionais), MATTER_STORAGE_PATH (pasta do pareamento; /data no compose).
import { Endpoint, ServerNode, VendorId } from "@matter/main";
import { BridgedDeviceBasicInformationServer } from "@matter/main/behaviors/bridged-device-basic-information";
import { ColorControlServer } from "@matter/main/behaviors/color-control";
import { DoorLockServer } from "@matter/main/behaviors/door-lock";
import { ThermostatServer } from "@matter/main/behaviors/thermostat";
import { WindowCoveringServer } from "@matter/main/behaviors/window-covering";
import {
  ContactSensorDevice, DimmableLightDevice, DoorLockDevice, ExtendedColorLightDevice, HumiditySensorDevice,
  OccupancySensorDevice, OnOffLightDevice, OnOffPlugInUnitDevice, TemperatureSensorDevice, ThermostatDevice,
  WindowCoveringDevice,
} from "@matter/main/devices";
import { AggregatorEndpoint } from "@matter/main/endpoints/aggregator";

const MA_URL = (process.env.MA_URL || "http://127.0.0.1").replace(/\/$/, "");
const KEY = process.env.MA_API_KEY;
const POLL_MS = Number(process.env.POLL_S || 3) * 1000;

// Fechadura sem PIN: o ecossistema pede a confirmação dele (Face ID, código de voz).
class Lock extends DoorLockServer {
  lockDoor() { this.state.lockState = 1; }
  unlockDoor() { this.state.lockState = 2; }
}

// Tipo do Rails → classe e o mínimo que o matter.js exige do cluster.
export const TYPES = {
  on_off_light: [OnOffLightDevice],
  on_off_plug: [OnOffPlugInUnitDevice],
  dimmable_light: [DimmableLightDevice],
  extended_color_light: [ExtendedColorLightDevice.with(ColorControlServer.with("HueSaturation", "Xy", "ColorTemperature")),
    { colorControl: { colorMode: 0, enhancedColorMode: 0, colorTempPhysicalMinMireds: 153, colorTempPhysicalMaxMireds: 500, coupleColorTempToLevelMinMireds: 153 } }],
  window_covering: [WindowCoveringDevice.with(WindowCoveringServer.with("Lift", "PositionAwareLift")), { windowCovering: { type: 0 } }],
  thermostat: [ThermostatDevice.with(ThermostatServer.with("Heating", "Cooling")),
    { thermostat: { controlSequenceOfOperation: 4, systemMode: 3 } }],
  door_lock: [DoorLockDevice.with(Lock), { doorLock: { lockType: 0, actuatorEnabled: true, operatingMode: 0, wrongCodeEntryLimit: 5, userCodeTemporaryDisableTime: 10 } }],
  contact_sensor: [ContactSensorDevice],
  occupancy_sensor: [OccupancySensorDevice, { occupancySensing: { occupancySensorType: 0, occupancySensorTypeBitmap: { pir: true } } }],
  temperature_sensor: [TemperatureSensorDevice],
  humidity_sensor: [HumiditySensorDevice],
};

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function api(method, path, body) {
  const res = await fetch(`${MA_URL}/api/v1/bridges/matter${path}`, {
    method, headers: { "X-Api-Key": KEY, "Content-Type": "application/json", Accept: "application/json" },
    body: body && JSON.stringify(body), signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok && res.status !== 204) throw new Error(`MA ${method} ${path}: ${res.status}`);
  return res.status === 204 ? null : res.json();
}

const merge = (a, b) => {
  const out = { ...a };
  for (const [k, v] of Object.entries(b || {})) out[k] = v && typeof v === "object" && !Array.isArray(v) ? merge(a?.[k], v) : v;
  return out;
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// Matter: id do endpoint sem hífen.
const epId = (id) => `p${String(id).replace(/-/g, "")}`;

export class Bridge {
  constructor(server, aggregator, send) {
    this.server = server;
    this.aggregator = aggregator;
    this.send = send; // (id, "cluster.atributo", valor) → comando no MA
    this.endpoints = new Map(); // id → {ep, type, name, applied}
  }

  // Lista do MA → endpoints (cria, atualiza, tira). Não comanda nada no MA.
  async sync(devices) {
    const seen = new Set();
    for (const d of devices) {
      const def = TYPES[d.type];
      if (!def) continue;
      seen.add(d.id);
      let cur = this.endpoints.get(d.id);
      if (cur && cur.type !== d.type) { await this.remove(d.id); cur = null; }
      if (!cur) { await this.add(d, def); continue; }
      if (cur.name !== d.name || cur.reachable !== d.reachable) {
        await cur.ep.set({ bridgedDeviceBasicInformation: { nodeLabel: d.name.slice(0, 32), reachable: d.reachable !== false } });
        Object.assign(cur, { name: d.name, reachable: d.reachable });
      }
      if (!same(cur.state, d.state)) await this.apply(cur, d.state);
    }
    for (const id of [...this.endpoints.keys()]) if (!seen.has(id)) await this.remove(id);
  }

  async add(d, [Type, defaults]) {
    const ep = new Endpoint(Type.with(BridgedDeviceBasicInformationServer), {
      id: epId(d.id),
      bridgedDeviceBasicInformation: { nodeLabel: d.name.slice(0, 32), productName: "Minha Automação", vendorName: (d.manufacturer || "Minha Automação").slice(0, 32),
        serialNumber: String(d.id).slice(0, 32), uniqueId: String(d.id).slice(0, 32), reachable: d.reachable !== false },
      ...merge(defaults, d.state),
    });
    await this.aggregator.add(ep);
    const cur = { ep, type: d.type, name: d.name, reachable: d.reachable, state: d.state, applied: {} };
    for (const path of d.listen || []) {
      const [cluster, attr] = path.split(".");
      cur.applied[path] = d.state?.[cluster]?.[attr];
      ep.events[cluster]?.[`${attr}$Changed`]?.on((value) => {
        if (same(value, cur.applied[path])) return; // eco do que veio do MA
        cur.applied[path] = value;
        this.send(d.id, path, value).catch((e) => log("comando falhou:", e.message));
      });
    }
    this.endpoints.set(d.id, cur);
    log("exposto:", d.type, d.name);
  }

  async apply(cur, state) {
    for (const path of Object.keys(cur.applied)) {
      const [cluster, attr] = path.split(".");
      if (state?.[cluster] && attr in state[cluster]) cur.applied[path] = state[cluster][attr];
    }
    cur.state = state;
    await cur.ep.set(state);
  }

  async remove(id) {
    const cur = this.endpoints.get(id);
    this.endpoints.delete(id);
    await cur?.ep.delete();
    log("removido:", cur?.name);
  }
}

export async function createServer() {
  const server = await ServerNode.create({
    id: "minha-automacao-bridge",
    network: { port: Number(process.env.MATTER_PORT || 5540) },
    commissioning: { passcode: Number(process.env.PASSCODE || 20202021), discriminator: Number(process.env.DISCRIMINATOR || 3840) },
    productDescription: { name: "Minha Automação", deviceType: AggregatorEndpoint.deviceType },
    basicInformation: { vendorName: "Minha Automação", vendorId: VendorId(0xfff1), nodeLabel: "Minha Automação", productName: "Ponte Minha Automação",
      productLabel: "Ponte Minha Automação", productId: 0x8000, serialNumber: "ma-bridge", uniqueId: "ma-bridge" },
  });
  const aggregator = new Endpoint(AggregatorEndpoint, { id: "aggregator" });
  await server.add(aggregator);
  return { server, aggregator };
}

export function status(server) {
  const c = server.state.commissioning;
  return { qr: c.pairingCodes.qrPairingCode, manual: c.pairingCodes.manualPairingCode, commissioned: c.commissioned,
    fabrics: Object.keys(c.fabrics || {}).length };
}

async function main() {
  if (!KEY) throw new Error("Falta MA_API_KEY (gere na tela Ponte Matter do local).");
  const { server, aggregator } = await createServer();
  const bridge = new Bridge(server, aggregator, (id, attribute, value) => api("POST", "/commands", { point_id: id, attribute, value }));
  await server.start();
  log("ponte Matter no ar");
  for (;;) {
    try {
      const { data } = await api("GET", "");
      await bridge.sync(data.devices);
      await api("PUT", "/status", status(server));
    } catch (e) {
      log("sem o MA:", e.message);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
