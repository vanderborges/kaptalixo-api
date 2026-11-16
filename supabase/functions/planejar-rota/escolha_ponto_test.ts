import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  abertoEm,
  candidatosAbertos,
  pontuar,
  valorEstimado,
} from "./escolha_ponto.ts";
import { planejar } from "./planejador.ts";
import {
  OsrmFakeFalha,
  OsrmFakeOtimo,
  P0,
  parada,
  rota,
} from "./testes_util.ts";
import type { ContextoDescarte, Horario, PontoCandidato } from "./tipos.ts";

// 2026-01-01 e quinta; 12:00Z = 09:00 em Sao Paulo.
const AGORA = new Date("2026-01-01T12:00:00.000Z");
const opc = (osrm = new OsrmFakeOtimo()) => ({ osrm, agora: () => AGORA });

const TODOS: Horario = Object.fromEntries(
  ["dom", "seg", "ter", "qua", "qui", "sex", "sab"].map((
    d,
  ) => [d, [["00:00", "23:59"]]]),
) as Horario;
const COLETA = { lat: P0.lat + 0.01, lng: P0.lng }; // unica coleta, ~1,1 km de P0

function ponto(
  id: string,
  dLat: number,
  precos: Record<number, number>,
  horario: Horario = TODOS,
): PontoCandidato {
  return {
    id,
    coord: { lat: COLETA.lat + dLat, lng: COLETA.lng },
    horario,
    precos,
  };
}
function ctx(
  pontos: PontoCandidato[],
  coletas = [{ peso_kg: 10, materiais: [1] }],
  custo_km = 0.9,
): ContextoDescarte {
  return { custo_km, coletas, pontos };
}
const rotaCom = (c: ContextoDescarte) =>
  rota([parada(1, COLETA)], { contexto_descarte: c });

Deno.test("mesmo percurso: vence quem paga mais (pontos equidistantes da ultima coleta)", async () => {
  const c = ctx([ponto("A", 0.02, { 1: 1.0 }), ponto("B", -0.02, { 1: 1.5 })]);
  const plano = await planejar(rotaCom(c), opc());
  assertEquals(plano.ponto_destino_id, "B");
  assertEquals(plano.alternativas_ponto?.map((a) => a.ponto_id), ["A"]);
  assertEquals(plano.origem_calculo, "osrm");
  const c2 = ctx([ponto("A", 0.02, { 1: 2.0 }), ponto("B", -0.02, { 1: 1.5 })]);
  assertEquals((await planejar(rotaCom(c2), opc())).ponto_destino_id, "A");
});

Deno.test("descarte e a ultima parada, nova (id null) e com o ponto escolhido", async () => {
  const c = ctx([ponto("A", 0.02, { 1: 1.0 })]);
  const plano = await planejar(rotaCom(c), opc());
  const ult = plano.paradas[plano.paradas.length - 1];
  assertEquals([ult.id, ult.tipo, ult.ponto_id], [null, "descarte", "A"]);
  assertEquals(plano.paradas.length, 2);
});

Deno.test("ponto fechado nunca e escolhido, mesmo pagando muito mais e mais perto", async () => {
  const fechado = ponto("FECHADO", 0.001, { 1: 50 }, {});
  const soSab = ponto("SO_SAB", 0.001, { 1: 50 }, {
    sab: [["00:00", "23:59"]],
  });
  const aberto = ponto("ABERTO", 0.05, { 1: 0.3 });
  const plano = await planejar(rotaCom(ctx([fechado, soSab, aberto])), opc());
  assertEquals(plano.ponto_destino_id, "ABERTO");
  assertEquals(plano.alternativas_ponto, []);
});

Deno.test("ponto que fecha antes da chegada estimada e descartado", async () => {
  // a chegada na coleta e ~09:03 (hora local); este ponto fecha 09:02
  const fecha = ponto("FECHA_CEDO", 0.001, { 1: 50 }, {
    qui: [["08:00", "09:02"]],
  });
  const ok = ponto("OK", 0.03, { 1: 1 });
  const plano = await planejar(rotaCom(ctx([fecha, ok])), opc());
  assertEquals(plano.ponto_destino_id, "OK");
});

Deno.test("so pontos fechados: nao escolhe nada e a rota continua sem descarte", async () => {
  const plano = await planejar(
    rotaCom(ctx([ponto("X", 0.01, { 1: 9 }, {})])),
    opc(),
  );
  assertEquals(plano.ponto_destino_id, undefined);
  assertEquals(plano.alternativas_ponto, undefined);
  assertEquals(plano.paradas.map((p) => p.tipo), ["coleta"]);
});

Deno.test("sem materiais declarados usa a media dos precos do ponto", async () => {
  const a = ponto("A", 0.02, { 1: 1, 2: 3 }); // media 2
  const b = ponto("B", -0.02, { 1: 4, 2: 0.2 }); // media 2,1
  const coletas = [{ peso_kg: 10, materiais: [] as number[] }];
  assertEquals(valorEstimado(a, coletas), 20);
  assertEquals(valorEstimado(b, coletas), 21);
  const plano = await planejar(rotaCom(ctx([a, b], coletas)), opc());
  assertEquals(plano.ponto_destino_id, "B");
  // com material declarado (so o 2), A paga mais: a media nao e usada
  const decl = [{ peso_kg: 10, materiais: [2] }];
  assertEquals(valorEstimado(a, decl), 30);
  const p2 = await planejar(rotaCom(ctx([a, b], decl)), opc());
  assertEquals(p2.ponto_destino_id, "A");
});

Deno.test("valor divide o peso entre os materiais declarados; material que o ponto nao compra vale 0", () => {
  const p = ponto("A", 0, { 1: 2, 2: 4 });
  assertEquals(valorEstimado(p, [{ peso_kg: 10, materiais: [1, 2] }]), 30);
  assertEquals(valorEstimado(p, [{ peso_kg: 10, materiais: [1, 9] }]), 10);
  assertEquals(
    valorEstimado(p, [
      { peso_kg: 4, materiais: [1] },
      { peso_kg: 6, materiais: [] },
    ]),
    8 + 18,
  );
});

Deno.test("score = valor - km x custo_km: ponto longe que paga mais perde se o desvio custa mais", async () => {
  const perto = ponto("PERTO", 0.005, { 1: 1.0 }); // ~0,55 km
  const longe = ponto("LONGE", 0.1, { 1: 1.2 }); // ~11 km: +2 R$ de valor, -10 R$ de desvio
  const plano = await planejar(rotaCom(ctx([perto, longe])), opc());
  assertEquals(plano.ponto_destino_id, "PERTO");
  // custo_km vem da configuracao: com custo 0, o que paga mais vence
  const p0 = await planejar(
    rotaCom(ctx([perto, longe], undefined, 0)),
    opc(),
  );
  assertEquals(p0.ponto_destino_id, "LONGE");
});

Deno.test("alternativas: 2o e 3o com score arredondado; so 5 candidatos", () => {
  const pts = [0.01, 0.02, 0.03, 0.04, 0.05, 0.06].map((d, i) =>
    ponto(`P${i}`, d, { 1: 1 + i * 0.05 })
  );
  const cand = candidatosAbertos(pts, COLETA, AGORA, 5);
  assertEquals(cand.map((p) => p.id), ["P0", "P1", "P2", "P3", "P4"]);
  const dist = [1000, 2000, 3000, 4000, 5000];
  const e = pontuar(ctx(cand), cand, dist, AGORA, 5)!;
  // scores: 10-0,9=9,10 ; 10,5-1,8=8,70 ; 11-2,7=8,30 ; 11,5-3,6=7,90 ; 12-4,5=7,50
  assertEquals(e.ponto.id, "P0");
  assertEquals(e.alternativas, [
    { ponto_id: "P1", score: 8.7 },
    { ponto_id: "P2", score: 8.3 },
  ]);
});

Deno.test("empate de score: maior valor, depois menor distancia", () => {
  const a = ponto("A", 0, { 1: 1 });
  const b = ponto("B", 0, { 1: 1 });
  const e = pontuar(ctx([a, b]), [a, b], [2000, 1000], AGORA, 5)!;
  assertEquals(e.ponto.id, "B");
});

Deno.test("OSRM table indisponivel: usa haversine, sinaliza origem_calculo e ainda escolhe", async () => {
  const c = ctx([ponto("A", 0.02, { 1: 1 }), ponto("B", -0.02, { 1: 2 })]);
  const plano = await planejar(rotaCom(c), opc(new OsrmFakeFalha()));
  assertEquals(plano.origem_calculo, "haversine");
  assertEquals(plano.ponto_destino_id, "B");
});

Deno.test("OSRM sem metodo distancias: cai em haversine sinalizado", async () => {
  const osrm = new OsrmFakeOtimo();
  // deno-lint-ignore no-explicit-any
  (osrm as any).distancias = undefined;
  const plano = await planejar(
    rotaCom(ctx([ponto("A", 0.02, { 1: 1 })])),
    opc(osrm),
  );
  assertEquals(plano.origem_calculo, "haversine");
  assertEquals(plano.ponto_destino_id, "A");
});

Deno.test("OSRM usado: uma consulta table e origem osrm", async () => {
  const osrm = new OsrmFakeOtimo();
  await planejar(rotaCom(ctx([ponto("A", 0.02, { 1: 1 })])), opc(osrm));
  assertEquals(osrm.consultasTable, 1);
});

Deno.test("rota ja com ponto de destino (troca manual): nao reescolhe", async () => {
  const manual = ponto("MANUAL", 0.02, { 1: 0.1 });
  const melhor = ponto("MELHOR", -0.02, { 1: 9 });
  const r = rota([parada(1, COLETA)], {
    ponto_destino_id: "MANUAL",
    destino: { ponto_id: "MANUAL", coord: manual.coord },
    contexto_descarte: ctx([manual, melhor]),
  });
  const plano = await planejar(r, opc());
  assertEquals(plano.ponto_destino_id, undefined);
  assertEquals(plano.paradas[plano.paradas.length - 1].ponto_id, "MANUAL");
});

Deno.test("ultima coleta e a da ordem otimizada (nao a ultima da lista)", async () => {
  const perto = { lat: P0.lat + 0.005, lng: P0.lng };
  const longe = { lat: P0.lat + 0.05, lng: P0.lng };
  const r = rota([parada(1, longe), parada(2, perto)], {
    contexto_descarte: ctx([
      {
        id: "NA_PERTO",
        coord: { lat: perto.lat - 0.001, lng: perto.lng },
        horario: TODOS,
        precos: { 1: 1 },
      },
      {
        id: "NA_LONGE",
        coord: { lat: longe.lat + 0.001, lng: longe.lng },
        horario: TODOS,
        precos: { 1: 1 },
      },
    ]),
  });
  const plano = await planejar(r, opc());
  assertEquals(plano.ponto_destino_id, "NA_LONGE");
});

Deno.test("abertoEm: fuso de Sao Paulo, fim exclusivo, dia ausente, dados invalidos", () => {
  const h: Horario = { qui: [["08:00", "17:00"]], sex: [["22:00", "02:00"]] };
  assert(abertoEm(h, new Date("2026-01-01T11:00:00Z"))); // qui 08:00
  assert(!abertoEm(h, new Date("2026-01-01T10:59:00Z"))); // qui 07:59
  assert(!abertoEm(h, new Date("2026-01-01T20:00:00Z"))); // qui 17:00 (fim exclusivo)
  assert(abertoEm(h, new Date("2026-01-01T19:59:00Z"))); // qui 16:59
  assert(!abertoEm(h, new Date("2026-01-02T02:00:00Z"))); // qui 23:00 local, nao sex
  assert(abertoEm(h, new Date("2026-01-03T01:30:00Z"))); // sex 22:30, ate meia-noite
  assert(!abertoEm({}, AGORA));
  assert(!abertoEm({ qui: [["xx", "yy"]] } as unknown as Horario, AGORA));
  assert(!abertoEm(null as unknown as Horario, AGORA));
});
