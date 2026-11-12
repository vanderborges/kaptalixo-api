import { assertEquals } from "jsr:@std/assert@1";
import { Chamador, criarHandler } from "./handler.ts";
import {
  OsrmFakeFalha,
  OsrmFakeOtimo,
  parada,
  RepoFake,
  rota,
} from "./testes_util.ts";

const DONO = "30000000-0000-4000-8000-000000000001";
const ROTA_ID = "20000000-0000-4000-8000-000000000001";

function montar(repo: RepoFake, osrm = new OsrmFakeOtimo()) {
  return criarHandler({
    osrm,
    repo,
    autenticar: (t): Promise<Chamador | null> =>
      Promise.resolve(
        t === "SERVICO"
          ? { tipo: "servico" }
          : t === "DONO"
          ? { tipo: "usuario", id: DONO }
          : t === "OUTRO"
          ? { tipo: "usuario", id: "99999999-0000-4000-8000-000000000009" }
          : null,
      ),
  });
}

function req(token: string | null, corpo: unknown, metodo = "POST"): Request {
  return new Request("http://local/planejar-rota", {
    method: metodo,
    headers: token
      ? { authorization: `Bearer ${token}`, "content-type": "application/json" }
      : {},
    body: metodo === "POST"
      ? (typeof corpo === "string" ? corpo : JSON.stringify(corpo))
      : undefined,
  });
}

const repoPadrao = () =>
  new RepoFake(rota([
    parada(1, { lat: -27.5, lng: -48.5 }),
    parada(2, { lat: -27.5905, lng: -48.5505 }),
  ]));

Deno.test("sem token ou token invalido: 401", async () => {
  const h = montar(repoPadrao());
  assertEquals((await h(req(null, { rota_id: ROTA_ID }))).status, 401);
  assertEquals((await h(req("LIXO", { rota_id: ROTA_ID }))).status, 401);
});

Deno.test("metodo diferente de POST: 405", async () => {
  const h = montar(repoPadrao());
  const r = await h(
    new Request("http://local/x", {
      method: "GET",
      headers: { authorization: "Bearer DONO" },
    }),
  );
  assertEquals(r.status, 405);
});

Deno.test("entrada invalida: 400", async () => {
  const h = montar(repoPadrao());
  assertEquals((await h(req("DONO", "nao-e-json"))).status, 400);
  assertEquals((await h(req("DONO", {}))).status, 400);
  assertEquals((await h(req("DONO", { rota_id: "abc" }))).status, 400);
  assertEquals((await h(req("DONO", { rota_id: 5 }))).status, 400);
});

Deno.test("catador que nao e dono: 403 e nada gravado", async () => {
  const repo = repoPadrao();
  const r = await montar(repo)(req("OUTRO", { rota_id: ROTA_ID }));
  assertEquals(r.status, 403);
  assertEquals(repo.gravados.length, 0);
});

Deno.test("dono: 200, grava plano e devolve versao+1 sem coordenadas", async () => {
  const repo = repoPadrao();
  const r = await montar(repo)(req("DONO", { rota_id: ROTA_ID }));
  assertEquals(r.status, 200);
  const corpo = await r.json();
  assertEquals(corpo.versao, 4);
  assertEquals(corpo.origem_calculo, "osrm");
  assertEquals(corpo.ordem.length, 2);
  assertEquals("polyline" in corpo, false);
  assertEquals(repo.gravados.length, 1);
});

Deno.test("service role pode planejar rota de qualquer catador", async () => {
  const r = await montar(repoPadrao())(req("SERVICO", { rota_id: ROTA_ID }));
  assertEquals(r.status, 200);
});

Deno.test("rota inexistente: 404", async () => {
  const r = await montar(new RepoFake(null))(
    req("SERVICO", { rota_id: ROTA_ID }),
  );
  assertEquals(r.status, 404);
});

Deno.test("OSRM fora do ar: 200 com origem_calculo haversine", async () => {
  const r = await montar(
    repoPadrao(),
    new OsrmFakeFalha() as unknown as OsrmFakeOtimo,
  )(
    req("DONO", { rota_id: ROTA_ID }),
  );
  assertEquals(r.status, 200);
  assertEquals((await r.json()).origem_calculo, "haversine");
});

Deno.test("conflito de versao: replaneja uma vez e conclui; persistente vira 409", async () => {
  const repo = repoPadrao();
  repo.conflitos = 1;
  assertEquals(
    (await montar(repo)(req("DONO", { rota_id: ROTA_ID }))).status,
    200,
  );
  const repo2 = repoPadrao();
  repo2.conflitos = 5;
  assertEquals(
    (await montar(repo2)(req("DONO", { rota_id: ROTA_ID }))).status,
    409,
  );
});

Deno.test("rota sem paradas: 422 sem_paradas", async () => {
  const r = await montar(new RepoFake(rota([])))(
    req("DONO", { rota_id: ROTA_ID }),
  );
  assertEquals(r.status, 422);
  assertEquals((await r.json()).erro, "sem_paradas");
});
