import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { ClienteOsrmHttp, interpretarTrip } from "./osrm.ts";
import { codificarPolyline, lerPonto } from "./geo.ts";
import { planejar } from "./planejador.ts";
import { P0, parada, rota } from "./testes_util.ts";

const fixture = JSON.parse(
  Deno.readTextFileSync(
    new URL("./fixtures/trip_3_coletas.json", import.meta.url),
  ),
);
const semRota = JSON.parse(
  Deno.readTextFileSync(
    new URL("./fixtures/trip_nenhuma_rota.json", import.meta.url),
  ),
);
const coords = [
  P0,
  { lat: -27.55, lng: -48.5 },
  { lat: -27.588, lng: -48.548 },
  { lat: -27.57, lng: -48.53 },
];

function respostaJson(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status });
}

Deno.test("interpretarTrip converte a fixture do OSRM (ordem e trechos)", () => {
  const r = interpretarTrip(fixture, 4);
  assertEquals(r.ordem, [0, 2, 3, 1]);
  assertEquals(r.trechos.map((t) => t.duracao_s), [61, 351, 513]);
  assertEquals(r.distancia_total_m, 7281);
});

Deno.test("cliente monta URL com source=first, destination=last, roundtrip=false e usa base configurada", async () => {
  let url = "";
  const c = new ClienteOsrmHttp({
    baseUrl: "http://osrm.local:5000/",
    timeoutMs: 1000,
    tentativas: 2,
    fetchFn: (u) => {
      url = String(u);
      return Promise.resolve(respostaJson(fixture));
    },
  });
  await c.trip(coords, true);
  assert(
    url.startsWith("http://osrm.local:5000/trip/v1/driving/-48.55,-27.59;"),
  );
  assert(url.includes("source=first"));
  assert(url.includes("destination=last"));
  assert(url.includes("roundtrip=false"));
  await c.trip(coords, false);
  assert(!url.includes("destination=last"));
});

Deno.test("1 retry: falha na primeira, sucesso na segunda", async () => {
  let n = 0;
  const c = new ClienteOsrmHttp({
    baseUrl: "http://x",
    timeoutMs: 1000,
    tentativas: 2,
    fetchFn: () => (++n === 1
      ? Promise.resolve(respostaJson({}, 503))
      : Promise.resolve(respostaJson(fixture))),
  });
  const r = await c.trip(coords, false);
  assertEquals(n, 2);
  assertEquals(r.ordem.length, 4);
});

Deno.test("sem sucesso apos o retry: erro (nao mais que 2 chamadas)", async () => {
  let n = 0;
  const c = new ClienteOsrmHttp({
    baseUrl: "http://x",
    timeoutMs: 1000,
    tentativas: 2,
    fetchFn: () => {
      n++;
      return Promise.resolve(respostaJson(semRota));
    },
  });
  await assertRejects(() => c.trip(coords, false), Error, "osrm_indisponivel");
  assertEquals(n, 2);
});

Deno.test("timeout curto aborta a requisicao pendurada", async () => {
  const c = new ClienteOsrmHttp({
    baseUrl: "http://x",
    timeoutMs: 50,
    tentativas: 1,
    fetchFn: (_u, init) =>
      new Promise((_res, rej) => {
        init!.signal!.addEventListener(
          "abort",
          () => rej(new Error("abortado")),
        );
      }),
  });
  const t0 = performance.now();
  await assertRejects(() => c.trip(coords, false), Error, "osrm_indisponivel");
  assert(performance.now() - t0 < 1000);
});

Deno.test("planejar com cliente HTTP + fixture: ordem otimizada da fixture e ETAs", async () => {
  const c = new ClienteOsrmHttp({
    baseUrl: "http://x",
    timeoutMs: 1000,
    tentativas: 2,
    fetchFn: () => Promise.resolve(respostaJson(fixture)),
  });
  const ps = [parada(1, coords[1]), parada(2, coords[2]), parada(3, coords[3])];
  const agora = new Date("2026-01-01T00:00:00.000Z");
  const plano = await planejar(rota(ps), { osrm: c, agora: () => agora });
  assertEquals(plano.paradas.map((p) => p.id), [ps[1].id, ps[2].id, ps[0].id]);
  assertEquals(
    plano.paradas[2].eta,
    new Date(agora.getTime() + (61 + 351 + 513) * 1000).toISOString(),
  );
  assertEquals(plano.polyline, fixture.trips[0].geometry);
});

Deno.test("polyline: codificacao conhecida e leitura de geography", () => {
  // Exemplo canonico da documentacao do Google: (38.5,-120.2),(40.7,-120.95),(43.252,-126.453)
  assertEquals(
    codificarPolyline([
      { lat: 38.5, lng: -120.2 },
      { lat: 40.7, lng: -120.95 },
      { lat: 43.252, lng: -126.453 },
    ]),
    "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
  );
  assertEquals(lerPonto({ type: "Point", coordinates: [-48.5, -27.5] }), {
    lng: -48.5,
    lat: -27.5,
  });
  assertEquals(lerPonto("SRID=4326;POINT(-48.5 -27.5)"), {
    lng: -48.5,
    lat: -27.5,
  });
  assertEquals(lerPonto(null), null);
});
