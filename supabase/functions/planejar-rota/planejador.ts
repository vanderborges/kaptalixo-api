import { codificarPolyline, haversineM } from "./geo.ts";
import {
  ClienteOsrm,
  Coord,
  ErroPlanejamento,
  OrigemCalculo,
  Plano,
  PlanoParada,
  ResultadoTrip,
  RotaCarregada,
} from "./tipos.ts";

export interface OpcoesPlanejador {
  osrm: ClienteOsrm;
  agora?: () => Date;
  /** Velocidade media (m/s) usada so no fallback haversine. */
  velocidadeFallbackMs?: number;
}

// Mesma convencao de aceitar_oferta (eta_s = distancia_m / 5).
const VELOCIDADE_FALLBACK_PADRAO_MS = 5;

/** Distancia haversine total de percorrer coords na ordem dada (indices em coords). */
function totalHaversine(coords: Coord[], ordem: number[]): number {
  let t = 0;
  for (let i = 1; i < ordem.length; i++) {
    t += haversineM(coords[ordem[i - 1]], coords[ordem[i]]);
  }
  return t;
}

/**
 * Fallback UC06: vizinho mais proximo a partir da origem (indice 0), destino (se houver) por ultimo.
 * Para garantir "ordem <= FIFO", compara com a ordem de chegada (FIFO) e fica com a menor.
 */
export function ordemFallback(coords: Coord[], destinoFixo: boolean): number[] {
  const n = coords.length;
  const ultimo = destinoFixo ? n - 1 : -1;
  const livres = new Set<number>();
  for (let i = 1; i < n; i++) if (i !== ultimo) livres.add(i);
  const fifo = [0, ...livres, ...(destinoFixo ? [ultimo] : [])];
  const nn = [0];
  while (livres.size > 0) {
    const atual = coords[nn[nn.length - 1]];
    let melhor = -1;
    let dMelhor = Infinity;
    for (const i of livres) {
      const d = haversineM(atual, coords[i]);
      if (d < dMelhor) {
        dMelhor = d;
        melhor = i;
      }
    }
    nn.push(melhor);
    livres.delete(melhor);
  }
  if (destinoFixo) nn.push(ultimo);
  return totalHaversine(coords, nn) <= totalHaversine(coords, fifo) ? nn : fifo;
}

function tripFallback(
  coords: Coord[],
  destinoFixo: boolean,
  velocidade: number,
): ResultadoTrip {
  const ordem = ordemFallback(coords, destinoFixo);
  const trechos = [];
  for (let i = 1; i < ordem.length; i++) {
    const d = Math.round(haversineM(coords[ordem[i - 1]], coords[ordem[i]]));
    trechos.push({ distancia_m: d, duracao_s: Math.round(d / velocidade) });
  }
  return {
    ordem,
    trechos,
    polyline: codificarPolyline(ordem.map((i) => coords[i])), // linha reta entre paradas
    distancia_total_m: trechos.reduce((s, t) => s + t.distancia_m, 0),
    duracao_total_s: trechos.reduce((s, t) => s + t.duracao_s, 0),
  };
}

function tripValido(
  r: ResultadoTrip,
  n: number,
  destinoFixo: boolean,
): boolean {
  if (r.ordem.length !== n || r.ordem[0] !== 0) return false;
  if (new Set(r.ordem).size !== n) return false;
  if (destinoFixo && r.ordem[n - 1] !== n - 1) return false;
  return r.trechos.length === n - 1;
}

/**
 * Calcula o plano da rota (UC06). Nao toca no banco: so usa o OSRM injetado.
 * - Paradas concluidas/puladas nao sao tocadas; `no_local` fica travada na frente.
 * - Paradas pendentes/a_caminho sao reordenadas; o descarte (se houver) e sempre a ultima.
 */
export async function planejar(
  rota: RotaCarregada,
  op: OpcoesPlanejador,
): Promise<Plano> {
  if (rota.status !== "planejada" && rota.status !== "em_andamento") {
    throw new ErroPlanejamento("rota_invalida", 422, "rota encerrada");
  }
  const agora = (op.agora ?? (() => new Date()))();
  const velocidade = op.velocidadeFallbackMs ?? VELOCIDADE_FALLBACK_PADRAO_MS;

  const porOrdem = [...rota.paradas].sort((a, b) => a.ordem - b.ordem);
  const finalizadas = porOrdem.filter((p) =>
    p.status === "concluida" || p.status === "pulada"
  );
  const travadas = porOrdem.filter((p) =>
    p.tipo === "coleta" && p.status === "no_local"
  );
  const pendentes = porOrdem.filter((p) =>
    p.tipo === "coleta" && (p.status === "pendente" || p.status === "a_caminho")
  );
  const descarteExistente = porOrdem.find((p) =>
    p.tipo === "descarte" && !finalizadas.includes(p)
  );

  const destino = rota.destino
    ? {
      id: descarteExistente?.id ?? null,
      ponto_id: rota.destino.ponto_id,
      coord: rota.destino.coord,
    }
    : descarteExistente
    ? {
      id: descarteExistente.id,
      ponto_id: descarteExistente.ponto_id,
      coord: descarteExistente.coord,
    }
    : null;

  if (pendentes.length === 0 && travadas.length === 0 && !destino) {
    throw new ErroPlanejamento(
      "sem_paradas",
      422,
      "rota sem paradas a planejar",
    );
  }

  let ordemBase = finalizadas.reduce((m, p) => Math.max(m, p.ordem), 0);
  const saida: PlanoParada[] = [];
  const iso = (s: number) => new Date(agora.getTime() + s * 1000).toISOString();

  // Paradas travadas (catador ja no local): ETA = agora, sem trecho.
  for (const p of travadas) {
    saida.push({
      id: p.id,
      ordem: ++ordemBase,
      tipo: "coleta",
      ponto_id: null,
      coord: p.coord,
      eta: iso(0),
      distancia_trecho_m: 0,
      duracao_trecho_s: 0,
    });
  }

  // Sem posicao do catador: parte da primeira parada pendente (trecho inicial de 0 m).
  const origem: Coord | null = travadas.length > 0
    ? travadas[travadas.length - 1].coord
    : rota.origem ?? pendentes[0]?.coord ?? destino?.coord ?? null;

  let origemCalculo: OrigemCalculo = "osrm";
  let polyline = "";
  let distanciaTotal = 0;
  let duracaoTotal = 0;
  let acumulado = 0;

  const alvos = [
    ...pendentes.map((p) => ({
      id: p.id as string | null,
      tipo: p.tipo as "coleta" | "descarte",
      ponto_id: null as string | null,
      coord: p.coord,
    })),
    ...(destino
      ? [{
        id: destino.id,
        tipo: "descarte" as const,
        ponto_id: destino.ponto_id,
        coord: destino.coord,
      }]
      : []),
  ];

  if (alvos.length > 0 && origem) {
    const coords = [origem, ...alvos.map((a) => a.coord)];
    const destinoFixo = destino !== null;
    let trip: ResultadoTrip;
    try {
      trip = await op.osrm.trip(coords, destinoFixo);
      if (!tripValido(trip, coords.length, destinoFixo)) {
        throw new Error("trip_invalido");
      }
    } catch (_e) {
      origemCalculo = "haversine";
      trip = tripFallback(coords, destinoFixo, velocidade);
    }
    polyline = trip.polyline;
    distanciaTotal = trip.distancia_total_m;
    duracaoTotal = trip.duracao_total_s;
    for (let pos = 1; pos < trip.ordem.length; pos++) {
      const alvo = alvos[trip.ordem[pos] - 1];
      const t = trip.trechos[pos - 1];
      acumulado += t.duracao_s;
      saida.push({
        id: alvo.id,
        ordem: ++ordemBase,
        tipo: alvo.tipo,
        ponto_id: alvo.ponto_id,
        coord: alvo.coord,
        eta: iso(acumulado),
        distancia_trecho_m: t.distancia_m,
        duracao_trecho_s: t.duracao_s,
      });
    }
  }

  return {
    origem_calculo: origemCalculo,
    distancia_total_m: distanciaTotal,
    duracao_total_s: duracaoTotal,
    polyline,
    paradas: saida,
  };
}
