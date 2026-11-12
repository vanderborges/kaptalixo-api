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
