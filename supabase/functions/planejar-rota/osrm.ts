import type { ClienteOsrm, Coord, ResultadoTrip } from "./tipos.ts";

export interface OpcoesOsrm {
  baseUrl: string;
  timeoutMs: number; // <= 4000
  tentativas: number; // 1 retry => 2
  fetchFn?: typeof fetch;
}

/** Cliente OSRM `trip`: timeout curto, 1 retry, dentro de um orcamento total. Nunca loga coordenadas. */
export class ClienteOsrmHttp implements ClienteOsrm {
  constructor(private op: OpcoesOsrm) {}

  async trip(
    coords: Coord[],
    destinoFixo: boolean,
    orcamentoMs?: number,
  ): Promise<ResultadoTrip> {
    const base = this.op.baseUrl.replace(/\/+$/, "");
    const lista = coords.map((c) => `${c.lng},${c.lat}`).join(";");
    const destino = destinoFixo ? "&destination=last" : "";
    const url =
      `${base}/trip/v1/driving/${lista}?source=first${destino}&roundtrip=false` +
      `&geometries=polyline&overview=full&steps=false`;
    const f = this.op.fetchFn ?? fetch;
    const fim = performance.now() + (orcamentoMs ?? Infinity);
    let ultimo: unknown;
    for (let i = 0; i < this.op.tentativas; i++) {
      // Orcamento total compartilhado entre tentativas: cada uma recebe no maximo o que sobra.
      const restante = fim - performance.now();
      if (restante < 50) break;
      try {
        const resp = await f(url, {
          signal: AbortSignal.timeout(Math.min(this.op.timeoutMs, restante)),
        });
        if (!resp.ok) throw new Error(`osrm_http_${resp.status}`);
        return interpretarTrip(await resp.json(), coords.length);
      } catch (e) {
        ultimo = e;
      }
    }
    throw new Error(
      `osrm_indisponivel: ${
        (ultimo as Error)?.message ?? "orcamento_esgotado"
      }`,
    );
  }
}

/** Valida OSRM_BASE_URL: so http/https, sem credenciais embutidas. */
export function validarBaseUrl(valor: string): string {
  let u: URL;
  try {
    u = new URL(valor);
  } catch {
    throw new Error("osrm_base_url_invalida");
  }
  if (
    (u.protocol !== "http:" && u.protocol !== "https:") || u.username ||
    u.password
  ) {
    throw new Error("osrm_base_url_invalida");
  }
  return valor;
}

// deno-lint-ignore no-explicit-any
export function interpretarTrip(corpo: any, n: number): ResultadoTrip {
  if (corpo?.code !== "Ok" || !corpo.trips?.[0]) {
    throw new Error(`osrm_codigo_${corpo?.code}`);
  }
  const viagem = corpo.trips[0];
  const wps = corpo.waypoints;
  if (!Array.isArray(wps) || wps.length !== n) {
    throw new Error("osrm_waypoints_invalidos");
  }
  const ordem: number[] = new Array(n).fill(-1);
  wps.forEach((w: { waypoint_index: number }, entrada: number) => {
    ordem[w.waypoint_index] = entrada;
  });
  if (ordem.some((x) => x < 0) || viagem.legs?.length !== n - 1) {
    throw new Error("osrm_resposta_inconsistente");
  }
  return {
    ordem,
    trechos: viagem.legs.map((l: { distance: number; duration: number }) => ({
      distancia_m: Math.round(l.distance),
      duracao_s: Math.round(l.duration),
    })),
    polyline: viagem.geometry,
    distancia_total_m: Math.round(viagem.distance),
    duracao_total_s: Math.round(viagem.duration),
  };
}
