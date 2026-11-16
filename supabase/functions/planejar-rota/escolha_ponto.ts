// UC07 / RN06: escolha do ponto de descarte. Funcoes puras (sem rede, sem banco).
import { haversineM } from "./geo.ts";
import type {
  AlternativaPonto,
  ContextoDescarte,
  Coord,
  Horario,
  PontoCandidato,
} from "./tipos.ts";

export const MAX_CANDIDATOS = 5;
const DIAS = ["dom", "seg", "ter", "qua", "qui", "sex", "sab"];
const FUSO = "America/Sao_Paulo"; // horario de funcionamento e local (sem horario de verao desde 2019)

const fmt = new Intl.DateTimeFormat("en-US", {
  timeZone: FUSO,
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

function minutos(hhmm: unknown): number | null {
  const m = typeof hhmm === "string" ? hhmm.match(/^(\d{1,2}):(\d{2})$/) : null;
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  return h <= 24 && mi < 60 ? h * 60 + mi : null;
}

/** Ponto aberto em `quando`? Fim exclusivo; intervalo com fim <= inicio vai ate meia-noite. Dado invalido = fechado. */
export function abertoEm(horario: Horario, quando: Date): boolean {
  const partes = Object.fromEntries(
    fmt.formatToParts(quando).map((p) => [p.type, p.value]),
  );
  const dia = (partes.weekday as string).toLowerCase().slice(0, 3);
  const chave = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].indexOf(dia);
  const intervalos = horario && typeof horario === "object"
    ? horario[DIAS[chave]]
    : undefined;
  if (!Array.isArray(intervalos)) return false;
  const t = Number(partes.hour) * 60 + Number(partes.minute);
  return intervalos.some((iv) => {
    const a = minutos(Array.isArray(iv) ? iv[0] : null);
    let b = minutos(Array.isArray(iv) ? iv[1] : null);
    if (a === null || b === null) return false;
    if (b <= a) b = 24 * 60;
    return t >= a && t < b;
  });
}

/** valor_estimado = soma(peso x preco_kg). Sem materiais declarados: media dos precos do ponto. */
export function valorEstimado(
  ponto: PontoCandidato,
  coletas: ContextoDescarte["coletas"],
): number {
  const precos = Object.values(ponto.precos);
  const media = precos.length
    ? precos.reduce((s, v) => s + v, 0) / precos.length
    : 0;
  let total = 0;
  for (const c of coletas) {
    if (c.materiais.length === 0) {
      total += c.peso_kg * media;
    } else {
      const fatia = c.peso_kg / c.materiais.length;
      for (const m of c.materiais) total += fatia * (ponto.precos[m] ?? 0);
    }
  }
  return total;
}

const chegada = (eta: Date, distM: number, vel: number) =>
  new Date(eta.getTime() + (distM / vel) * 1000);

/** Os 5 pontos mais proximos (linha reta) da ultima coleta que estarao abertos na chegada estimada. */
export function candidatosAbertos(
  pontos: PontoCandidato[],
  ultima: Coord,
  etaUltima: Date,
  velocidade: number,
): PontoCandidato[] {
  return pontos
    .map((p) => ({ p, d: haversineM(ultima, p.coord) }))
    .filter(({ p, d }) =>
      abertoEm(p.horario, chegada(etaUltima, d, velocidade))
    )
    .sort((a, b) => a.d - b.d || (a.p.id < b.p.id ? -1 : 1))
    .slice(0, MAX_CANDIDATOS)
    .map(({ p }) => p);
}

export interface Escolha {
  ponto: PontoCandidato;
  /** 2o e 3o colocados. */
  alternativas: AlternativaPonto[];
}

const arred = (v: number) => Math.round(v * 100) / 100;

/**
 * score = valor_estimado - km_adicionais x custo_km. `distanciasM[i]` e a distancia da ultima coleta
 * ate candidatos[i]. Reconfere o horario com a distancia final; fechado nunca vence.
 * Desempate: maior valor, depois menor distancia, depois id.
 */
export function pontuar(
  ctx: ContextoDescarte,
  candidatos: PontoCandidato[],
  distanciasM: number[],
  etaUltima: Date,
  velocidade: number,
): Escolha | null {
  const lista = candidatos
    .map((p, i) => {
      const valor = valorEstimado(p, ctx.coletas);
      const km = distanciasM[i] / 1000;
      return {
        p,
        valor,
        km,
        score: valor - km * ctx.custo_km,
        d: distanciasM[i],
      };
    })
    .filter((x) =>
      Number.isFinite(x.score) &&
      abertoEm(x.p.horario, chegada(etaUltima, x.d, velocidade))
    )
    .sort((a, b) =>
      b.score - a.score || b.valor - a.valor || a.d - b.d ||
      (a.p.id < b.p.id ? -1 : 1)
    );
  if (lista.length === 0) return null;
  return {
    ponto: lista[0].p,
    alternativas: lista.slice(1, 3).map((x) => ({
      ponto_id: x.p.id,
      score: arred(x.score),
    })),
  };
}
