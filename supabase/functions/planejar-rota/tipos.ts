// Tipos e contratos da Edge Function planejar-rota (UC06).

export interface Coord {
  lat: number;
  lng: number;
}

export type StatusParada =
  | "pendente"
  | "a_caminho"
  | "no_local"
  | "concluida"
  | "pulada";

export interface ParadaRota {
  id: string;
  ordem: number;
  tipo: "coleta" | "descarte";
  status: StatusParada;
  solicitacao_id: string | null;
  ponto_id: string | null;
  coord: Coord;
}

/** Intervalos de funcionamento por dia: {"seg":[["08:00","17:00"]],...}; dia ausente = fechado. */
export type Horario = Record<string, [string, string][]>;

export interface PontoCandidato {
  id: string;
  coord: Coord;
  horario: Horario;
  /** preco_kg por material_id (so materiais que o ponto compra). */
  precos: Record<number, number>;
}

/** Dados do UC07/RN06: so carregados quando a rota ainda nao tem ponto_destino_id. */
export interface ContextoDescarte {
  /** parametros.custo_km_reais (RN06). */
  custo_km: number;
  /** Uma entrada por solicitacao da rota (nao pulada): peso (RN07) e materiais declarados. */
  coletas: { peso_kg: number; materiais: number[] }[];
  /** Pontos ativos. */
  pontos: PontoCandidato[];
}

export interface AlternativaPonto {
  ponto_id: string;
  score: number;
}

export interface RotaCarregada {
  id: string;
  catador_id: string;
  status: "planejada" | "em_andamento" | "concluida" | "cancelada";
  versao: number;
  ponto_destino_id: string | null;
  /** Posicao atual do catador (P0); null se ainda nao informada. */
  origem: Coord | null;
  /** Ponto de descarte D (UC07/T4.3), se ja escolhido. */
  destino: { ponto_id: string; coord: Coord } | null;
  paradas: ParadaRota[];
  /** Presente so quando ponto_destino_id e null e ha coletas (T4.3). */
  contexto_descarte?: ContextoDescarte | null;
}

export type OrigemCalculo = "osrm" | "haversine";

export interface PlanoParada {
  /** id da parada existente; null = parada de descarte nova (inserir). */
  id: string | null;
  ordem: number;
  tipo: "coleta" | "descarte";
  ponto_id: string | null;
  coord: Coord;
  eta: string; // ISO 8601
  distancia_trecho_m: number;
  duracao_trecho_s: number;
}

export interface Plano {
  origem_calculo: OrigemCalculo;
  distancia_total_m: number;
  duracao_total_s: number;
  polyline: string;
  paradas: PlanoParada[];
  /** Definidos so quando a funcao escolheu o ponto agora (UC07); gravados em rotas. */
  ponto_destino_id?: string;
  alternativas_ponto?: AlternativaPonto[];
}

/** Resultado normalizado do OSRM `trip`. */
export interface ResultadoTrip {
  /** Indices das coordenadas de entrada na ordem de viagem (0 = origem). */
  ordem: number[];
  /** legs[k] liga o k-esimo ao (k+1)-esimo ponto da viagem. */
  trechos: { distancia_m: number; duracao_s: number }[];
  polyline: string;
  distancia_total_m: number;
  duracao_total_s: number;
}

export interface ClienteOsrm {
  /** coords[0] e a origem; se destinoFixo, o ultimo ponto e o destino. */
  trip(
    coords: Coord[],
    destinoFixo: boolean,
    orcamentoMs?: number,
  ): Promise<ResultadoTrip>;
  /** OSRM `table`: distancia (m) por estrada de `origem` a cada destino (UC07). Opcional. */
  distancias?(
    origem: Coord,
    destinos: Coord[],
    orcamentoMs?: number,
  ): Promise<number[]>;
}

export interface RepositorioRota {
  carregar(rotaId: string): Promise<RotaCarregada | null>;
  /** Grava o plano se rotas.versao ainda == versaoLida (bloqueio otimista). false = conflito. */
  gravar(rota: RotaCarregada, plano: Plano): Promise<boolean>;
}

export class ErroPlanejamento extends Error {
  constructor(public codigo: string, public status: number, mensagem?: string) {
    super(mensagem ?? codigo);
  }
}
