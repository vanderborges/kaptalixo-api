// Utilitarios SOMENTE de teste: fakes de OSRM e repositorio. Nenhuma chamada de rede.
import { haversineM } from "./geo.ts";
import type {
  ClienteOsrm,
  Coord,
  ParadaRota,
  Plano,
  RepositorioRota,
  ResultadoTrip,
  RotaCarregada,
} from "./tipos.ts";

export const P0: Coord = { lat: -27.59, lng: -48.55 };

/** OSRM falso "otimo": forca bruta por haversine (como o trip do OSRM faz para n <= 9). */
export class OsrmFakeOtimo implements ClienteOsrm {
  chamadas = 0;
  async trip(coords: Coord[], destinoFixo: boolean): Promise<ResultadoTrip> {
    this.chamadas++;
    const n = coords.length;
    const meio = [];
    for (let i = 1; i < (destinoFixo ? n - 1 : n); i++) meio.push(i);
    let melhor: number[] = [];
    let dMelhor = Infinity;
    const permutar = (resto: number[], atual: number[]) => {
      if (resto.length === 0) {
        const o = [0, ...atual, ...(destinoFixo ? [n - 1] : [])];
        let d = 0;
        for (let i = 1; i < o.length; i++) {
          d += haversineM(coords[o[i - 1]], coords[o[i]]);
        }
        if (d < dMelhor) {
          dMelhor = d;
          melhor = o;
        }
        return;
      }
      for (let i = 0; i < resto.length; i++) {
        permutar([...resto.slice(0, i), ...resto.slice(i + 1)], [
          ...atual,
          resto[i],
        ]);
      }
    };
    permutar(meio, []);
    const trechos = [];
    for (let i = 1; i < melhor.length; i++) {
      const d = Math.round(
        haversineM(coords[melhor[i - 1]], coords[melhor[i]]) * 1.3,
      );
      trechos.push({ distancia_m: d, duracao_s: Math.round(d / 8) });
    }
    return {
      ordem: melhor,
      trechos,
      polyline: "fake",
      distancia_total_m: trechos.reduce((s, t) => s + t.distancia_m, 0),
      duracao_total_s: trechos.reduce((s, t) => s + t.duracao_s, 0),
    };
  }
}

export class OsrmFakeFalha implements ClienteOsrm {
  chamadas = 0;
  trip(): Promise<ResultadoTrip> {
    this.chamadas++;
    return Promise.reject(new Error("osrm_indisponivel"));
  }
}

export function parada(
  n: number,
  coord: Coord,
  extra: Partial<ParadaRota> = {},
): ParadaRota {
  return {
    id: `00000000-0000-4000-8000-00000000000${n}`,
    ordem: n,
    tipo: "coleta",
    status: "pendente",
    solicitacao_id: `10000000-0000-4000-8000-00000000000${n}`,
    ponto_id: null,
    coord,
    ...extra,
  };
}

export function rota(
  paradas: ParadaRota[],
  extra: Partial<RotaCarregada> = {},
): RotaCarregada {
  return {
    id: "20000000-0000-4000-8000-000000000001",
    catador_id: "30000000-0000-4000-8000-000000000001",
    status: "planejada",
    versao: 3,
    ponto_destino_id: null,
    origem: P0,
    destino: null,
    paradas,
    ...extra,
  };
}

export class RepoFake implements RepositorioRota {
  gravados: { rota: RotaCarregada; plano: Plano }[] = [];
  /** Quantas gravacoes devem falhar por conflito de versao antes de aceitar. */
  conflitos = 0;
  constructor(public r: RotaCarregada | null) {}
  carregar(): Promise<RotaCarregada | null> {
    return Promise.resolve(this.r);
  }
  gravar(rota: RotaCarregada, plano: Plano): Promise<boolean> {
    if (this.conflitos > 0) {
      this.conflitos--;
      return Promise.resolve(false);
    }
    this.gravados.push({ rota, plano });
    return Promise.resolve(true);
  }
}

export function distanciaOrdem(origem: Coord, coords: Coord[]): number {
  let t = 0;
  let a = origem;
  for (const c of coords) {
    t += haversineM(a, c);
    a = c;
  }
  return t;
}
