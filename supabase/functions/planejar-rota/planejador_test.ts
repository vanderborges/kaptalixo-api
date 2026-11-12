import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { planejar } from "./planejador.ts";
import { ErroPlanejamento } from "./tipos.ts";
import {
  distanciaOrdem,
  OsrmFakeFalha,
  OsrmFakeOtimo,
  P0,
  parada,
  rota,
} from "./testes_util.ts";

const AGORA = new Date("2026-01-01T12:00:00.000Z");
const opc = (osrm = new OsrmFakeOtimo()) => ({ osrm, agora: () => AGORA });

// PRNG deterministico para casos "aleatorios" reproduziveis.
function prng(semente: number) {
  let s = semente;
  return () => (s = (s * 1664525 + 1013904223) % 4294967296) / 4294967296;
}

function casoAleatorio(r: () => number, n: number) {
  return Array.from(
    { length: n },
    (_, i) =>
      parada(i + 1, {
        lat: P0.lat + (r() - 0.5) * 0.1,
        lng: P0.lng + (r() - 0.5) * 0.1,
      }),
  );
}

Deno.test("ordem otimizada <= FIFO em 50 casos de 3 coletas (OSRM mockado)", async () => {
  const r = prng(42);
  for (let k = 0; k < 50; k++) {
    const ps = casoAleatorio(r, 3);
    const plano = await planejar(rota(ps), opc());
    const porId = new Map(ps.map((p) => [p.id, p.coord]));
    const otimo = distanciaOrdem(
      P0,
      plano.paradas.map((p) => porId.get(p.id!)!),
    );
    const fifo = distanciaOrdem(P0, ps.map((p) => p.coord));
    assert(otimo <= fifo + 1e-6, `caso ${k}: otimo ${otimo} > fifo ${fifo}`);
    assertEquals(plano.origem_calculo, "osrm");
  }
});

Deno.test("fallback haversine: existe rota, sinalizada e <= FIFO", async () => {
  const r = prng(7);
  for (let k = 0; k < 50; k++) {
    const ps = casoAleatorio(r, 3);
    const osrm = new OsrmFakeFalha();
    const plano = await planejar(rota(ps), opc(osrm));
    assertEquals(osrm.chamadas, 1);
    assertEquals(plano.origem_calculo, "haversine");
    assertEquals(plano.paradas.length, 3);
    assert(plano.polyline.length > 0);
    const porId = new Map(ps.map((p) => [p.id, p.coord]));
    const d = distanciaOrdem(P0, plano.paradas.map((p) => porId.get(p.id!)!));
    assert(d <= distanciaOrdem(P0, ps.map((p) => p.coord)) + 1e-6);
  }
});

Deno.test("fallback e vizinho mais proximo quando melhor que FIFO", async () => {
  const longe = parada(1, { lat: -27.5, lng: -48.5 });
  const perto = parada(2, { lat: -27.5905, lng: -48.5505 });
  const plano = await planejar(rota([longe, perto]), opc(new OsrmFakeFalha()));
  assertEquals(plano.paradas.map((p) => p.id), [perto.id, longe.id]);
});

Deno.test("ordem, ETA acumulado e trechos coerentes; versao nao e alterada aqui", async () => {
  const ps = casoAleatorio(prng(1), 4);
  const plano = await planejar(rota(ps), opc());
  assertEquals(plano.paradas.map((p) => p.ordem), [1, 2, 3, 4]);
  let acc = 0;
  for (const p of plano.paradas) {
    acc += p.duracao_trecho_s;
    assertEquals(p.eta, new Date(AGORA.getTime() + acc * 1000).toISOString());
  }
  assertEquals(plano.duracao_total_s, acc);
  assertEquals(
    plano.distancia_total_m,
    plano.paradas.reduce((s, p) => s + p.distancia_trecho_m, 0),
  );
});

Deno.test("descarte fica sempre por ultimo (destination=last) e e inserido se novo", async () => {
  const ps = casoAleatorio(prng(3), 3);
  const destino = {
    ponto_id: "40000000-0000-4000-8000-000000000001",
    coord: { lat: -27.7, lng: -48.4 },
  };
  const plano = await planejar(rota(ps, { destino }), opc());
  assertEquals(plano.paradas.length, 4);
  const ult = plano.paradas[3];
  assertEquals(ult.tipo, "descarte");
  assertEquals(ult.id, null);
  assertEquals(ult.ponto_id, destino.ponto_id);
});

Deno.test("fallback com descarte mantem descarte por ultimo", async () => {
  const ps = casoAleatorio(prng(5), 3);
  const destino = {
    ponto_id: "40000000-0000-4000-8000-000000000001",
    coord: { lat: -27.58, lng: -48.56 },
  };
  const plano = await planejar(rota(ps, { destino }), opc(new OsrmFakeFalha()));
  assertEquals(plano.paradas[3].tipo, "descarte");
});

Deno.test("paradas concluidas/puladas nao sao tocadas; ordem continua depois delas", async () => {
  const feita = parada(1, { lat: -27.6, lng: -48.6 }, { status: "concluida" });
  const pulada = parada(2, { lat: -27.6, lng: -48.61 }, { status: "pulada" });
  const a = parada(3, { lat: -27.5, lng: -48.5 });
  const b = parada(4, { lat: -27.5905, lng: -48.5505 });
  const plano = await planejar(rota([feita, pulada, a, b]), opc());
  assertEquals(plano.paradas.map((p) => p.id), [b.id, a.id]);
  assertEquals(plano.paradas.map((p) => p.ordem), [3, 4]);
});

Deno.test("parada no_local fica travada na frente e vira a origem", async () => {
  const aqui = parada(1, { lat: -27.58, lng: -48.54 }, { status: "no_local" });
  const a = parada(2, { lat: -27.5, lng: -48.5 });
  const plano = await planejar(rota([aqui, a]), opc());
  assertEquals(plano.paradas[0].id, aqui.id);
  assertEquals(plano.paradas[0].duracao_trecho_s, 0);
  assertEquals(plano.paradas[1].id, a.id);
});

Deno.test("sem posicao do catador: parte da primeira parada, sem falhar", async () => {
  const ps = casoAleatorio(prng(9), 2);
  const plano = await planejar(rota(ps, { origem: null }), opc());
  assertEquals(plano.paradas.length, 2);
});

Deno.test("resposta invalida do OSRM (nao permutacao) cai no fallback", async () => {
  const ps = casoAleatorio(prng(11), 2);
  const ruim = {
    trip: () =>
      Promise.resolve({
        ordem: [0, 1, 1],
        trechos: [{ distancia_m: 1, duracao_s: 1 }, {
          distancia_m: 1,
          duracao_s: 1,
        }],
        polyline: "x",
        distancia_total_m: 2,
        duracao_total_s: 2,
      }),
  };
  const plano = await planejar(rota(ps), { osrm: ruim, agora: () => AGORA });
  assertEquals(plano.origem_calculo, "haversine");
});

Deno.test("rota encerrada ou sem paradas: erro estavel", async () => {
  await assertRejects(
    () => planejar(rota([parada(1, P0)], { status: "concluida" }), opc()),
    ErroPlanejamento,
    "rota encerrada",
  );
  await assertRejects(
    () => planejar(rota([]), opc()),
    ErroPlanejamento,
    "sem paradas",
  );
});

Deno.test("5 paradas planejadas em < 3 s (OSRM mockado)", async () => {
  const ps = casoAleatorio(prng(21), 5);
  const t0 = performance.now();
  const plano = await planejar(rota(ps), opc());
  const ms = performance.now() - t0;
  assertEquals(plano.paradas.length, 5);
  assert(ms < 3000, `demorou ${ms} ms`);
});
