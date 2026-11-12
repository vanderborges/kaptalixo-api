import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { igualConstante } from "./auth.ts";
import { falha } from "./erros.ts";
import { criarHandler } from "./handler.ts";
import { ClienteOsrmHttp, validarBaseUrl } from "./osrm.ts";
import { planejar } from "./planejador.ts";
import type { ClienteOsrm, Coord } from "./tipos.ts";
import { OsrmFakeOtimo, P0, parada, RepoFake, rota } from "./testes_util.ts";

const ROTA_ID = "20000000-0000-4000-8000-000000000001";
const cinco = () =>
  Array.from(
    { length: 5 },
    (_, i) =>
      parada(i + 1, { lat: P0.lat + i * 0.01, lng: P0.lng - i * 0.007 }),
  );

function req(): Request {
  return new Request("http://local/x", {
    method: "POST",
    headers: { authorization: "Bearer T", "content-type": "application/json" },
    body: JSON.stringify({ rota_id: ROTA_ID }),
  });
}

/** OSRM que nunca responde (timeout simulado). */
const osrmPendurado: ClienteOsrm = { trip: () => new Promise(() => {}) };

Deno.test("OSRM pendurado: orcamento padrao (2,5 s) estoura e responde com fallback em < 3 s", async () => {
  const repo = new RepoFake(rota(cinco()));
  const h = criarHandler({
    osrm: osrmPendurado,
    repo,
    autenticar: () => Promise.resolve({ tipo: "servico" }),
  });
  const t0 = performance.now();
  const r = await h(req());
  const ms = performance.now() - t0;
  assertEquals(r.status, 200);
  assertEquals((await r.json()).origem_calculo, "haversine");
  assert(ms < 3000, `demorou ${ms} ms`);
  assert(ms >= 2400, `deveria ter esperado o orcamento, levou ${ms} ms`);
});

Deno.test("orcamento e compartilhado com o replanejamento (nao dobra)", async () => {
  const repo = new RepoFake(rota(cinco()));
  repo.conflitos = 1; // forca 2a rodada
  const h = criarHandler({
    osrm: osrmPendurado,
    repo,
    orcamentoMs: 600,
    autenticar: () => Promise.resolve({ tipo: "servico" }),
  });
  const t0 = performance.now();
  const r = await h(req());
  const ms = performance.now() - t0;
  assertEquals(r.status, 200);
  assert(ms < 1000, `2 rodadas somaram ${ms} ms (> orcamento)`);
});

Deno.test("cliente HTTP: 2 tentativas x timeout de 2 s respeitam orcamento de 500 ms", async () => {
  let chamadas = 0;
  const c = new ClienteOsrmHttp({
    baseUrl: "http://x",
    timeoutMs: 2000,
    tentativas: 2,
    fetchFn: (_u, init) =>
      new Promise((_res, rej) => {
        chamadas++;
        init!.signal!.addEventListener(
          "abort",
          () => rej(new Error("abortado")),
        );
      }),
  });
  const coords: Coord[] = [P0, { lat: -27.5, lng: -48.5 }];
  const t0 = performance.now();
  try {
    await c.trip(coords, false, 500);
  } catch { /* esperado */ }
  const ms = performance.now() - t0;
  assert(ms < 800, `levou ${ms} ms`);
  assert(chamadas >= 1 && chamadas <= 2);
});

Deno.test("prazo ja vencido: nem chama o OSRM, usa fallback", async () => {
  const osrm = new OsrmFakeOtimo();
  const plano = await planejar(rota(cinco()), {
    osrm,
    prazo: performance.now() - 1,
  });
  assertEquals(osrm.chamadas, 0);
  assertEquals(plano.origem_calculo, "haversine");
});

Deno.test("garantia <= FIFO tambem no resultado do OSRM: ordem pior vira fallback", async () => {
  const longe = parada(1, { lat: -27.5, lng: -48.5 });
  const perto = parada(2, { lat: -27.5905, lng: -48.5505 });
  // OSRM "ruim": devolve a ordem FIFO invertida de proposito (longe depois... pior que perto-primeiro)
  const ruim: ClienteOsrm = {
    trip: () =>
      Promise.resolve({
        ordem: [0, 1, 2], // longe, perto: pior em linha reta que [0,2,1]
        trechos: [{ distancia_m: 1, duracao_s: 1 }, {
          distancia_m: 1,
          duracao_s: 1,
        }],
        polyline: "x",
        distancia_total_m: 2,
        duracao_total_s: 2,
      }),
  };
  // FIFO aqui = [longe, perto] e o OSRM devolveu exatamente FIFO: empate, mantem OSRM.
  const p1 = await planejar(rota([longe, perto]), { osrm: ruim });
  assertEquals(p1.origem_calculo, "osrm");
  // Agora a ordem ruim e [perto-ultimo] contra FIFO melhor: FIFO = [perto, longe].
  const p2 = await planejar(
    rota([{ ...perto, ordem: 1 }, { ...longe, ordem: 2 }]),
    {
      osrm: {
        trip: () =>
          ruim.trip([], false).then((r) => ({ ...r, ordem: [0, 2, 1] })),
      },
    },
  );
  assertEquals(p2.origem_calculo, "haversine");
  assertEquals(p2.paradas[0].id, perto.id);
});

Deno.test("validarBaseUrl: so http/https sem credenciais", () => {
  assertEquals(
    validarBaseUrl("https://osrm.exemplo.org"),
    "https://osrm.exemplo.org",
  );
  assertEquals(
    validarBaseUrl("http://localhost:5000"),
    "http://localhost:5000",
  );
  for (
    const ruim of [
      "ftp://x",
      "file:///etc/passwd",
      "javascript:1",
      "nao-url",
      "https://u:s@x.org",
    ]
  ) {
    assertThrows(() => validarBaseUrl(ruim), Error, "osrm_base_url_invalida");
  }
});

Deno.test("igualConstante compara corretamente", async () => {
  assertEquals(await igualConstante("segredo", "segredo"), true);
  assertEquals(await igualConstante("segredo", "segredx"), false);
  assertEquals(await igualConstante("a", "aa"), false);
  assertEquals(await igualConstante("", ""), true);
});

Deno.test("falha() nao repassa mensagem do PostgREST (coordenadas)", () => {
  const e = assertThrows(
    () =>
      falha(
        "rota_paradas.update",
        {
          code: "23514",
          message: "Failing row contains (POINT(-48.5 -27.5))",
        } as { code: string },
      ),
    Error,
  );
  assertEquals(e.message, "rota_paradas.update: 23514");
  assert(!e.message.includes("POINT"));
});
