import { OpcoesPlanejador, planejar } from "./planejador.ts";
import { ErroPlanejamento, RepositorioRota } from "./tipos.ts";

export type Chamador = { tipo: "servico" } | { tipo: "usuario"; id: string };

export interface DepsHandler extends OpcoesPlanejador {
  repo: RepositorioRota;
  /** Orcamento total (ms) do OSRM, compartilhado entre tentativas e replanejamentos. Padrao 2500. */
  orcamentoMs?: number;
  /** Valida o token Bearer; null = invalido. */
  autenticar(token: string): Promise<Chamador | null>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

/** Cria o handler HTTP. Autorizacao: service role ou o catador dono da rota. */
export function criarHandler(
  deps: DepsHandler,
): (req: Request) => Promise<Response> {
  return async (req) => {
    const prazo = performance.now() + (deps.orcamentoMs ?? 2500);
    try {
      if (req.method !== "POST") {
        return json({ erro: "metodo_nao_permitido" }, 405);
      }
      const m = (req.headers.get("authorization") ?? "").match(
        /^Bearer\s+(.+)$/i,
      );
      const chamador = m ? await deps.autenticar(m[1].trim()) : null;
      if (!chamador) return json({ erro: "nao_autenticado" }, 401);

      let corpo: { rota_id?: unknown };
      try {
        corpo = await req.json();
      } catch {
        return json({ erro: "entrada_invalida" }, 400);
      }
      const rotaId = corpo?.rota_id;
      if (typeof rotaId !== "string" || !UUID.test(rotaId)) {
        return json({ erro: "entrada_invalida" }, 400);
      }

      // Ate 2 tentativas: se aceitar_oferta alterar a rota durante o calculo, rele e replaneja.
      for (let tentativa = 0; tentativa < 2; tentativa++) {
        const rota = await deps.repo.carregar(rotaId);
        if (!rota) return json({ erro: "rota_inexistente" }, 404);
        if (chamador.tipo === "usuario" && rota.catador_id !== chamador.id) {
          return json({ erro: "sem_permissao" }, 403);
        }
        const plano = await planejar(rota, { ...deps, prazo });
        if (await deps.repo.gravar(rota, plano)) {
          return json({
            rota_id: rota.id,
            versao: rota.versao + 1,
            origem_calculo: plano.origem_calculo,
            distancia_total_m: plano.distancia_total_m,
            duracao_total_s: plano.duracao_total_s,
            ordem: plano.paradas.map((p) => p.id),
          });
        }
      }
      return json({ erro: "conflito_versao" }, 409);
    } catch (e) {
      if (e instanceof ErroPlanejamento) {
        return json({ erro: e.codigo }, e.status);
      }
      console.error("planejar-rota: falha interna:", (e as Error)?.message); // sem coordenadas
      return json({ erro: "erro_interno" }, 500);
    }
  };
}
