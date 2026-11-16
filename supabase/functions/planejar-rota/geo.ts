import type { Coord } from "./tipos.ts";

export function haversineM(a: Coord, b: Coord): number {
  const R = 6371008.8;
  const rad = (g: number) => (g * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/** Codifica uma sequencia de pontos em polyline (precisao 5, mesmo formato do OSRM). */
export function codificarPolyline(pontos: Coord[]): string {
  let saida = "";
  let latAnt = 0;
  let lngAnt = 0;
  const emitir = (valor: number) => {
    let v = valor < 0 ? ~(valor << 1) : valor << 1;
    while (v >= 0x20) {
      saida += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
      v >>= 5;
    }
    saida += String.fromCharCode(v + 63);
  };
  for (const p of pontos) {
    const lat = Math.round(p.lat * 1e5);
    const lng = Math.round(p.lng * 1e5);
    emitir(lat - latAnt);
    emitir(lng - lngAnt);
    latAnt = lat;
    lngAnt = lng;
  }
  return saida;
}

/** Interpreta geography vinda do PostgREST (GeoJSON) ou texto WKT/EWKT. */
export function lerPonto(v: unknown): Coord | null {
  if (v == null) return null;
  if (typeof v === "object") {
    const c = (v as { coordinates?: unknown }).coordinates;
    if (Array.isArray(c) && c.length >= 2) {
      return { lng: Number(c[0]), lat: Number(c[1]) };
    }
    return null;
  }
  if (typeof v === "string") {
    const m = v.match(/POINT\s*\(\s*(-?[\d.]+)\s+(-?[\d.]+)\s*\)/i);
    if (m) return { lng: Number(m[1]), lat: Number(m[2]) };
  }
  return null;
}

export function ewkt(c: Coord): string {
  return `SRID=4326;POINT(${c.lng} ${c.lat})`;
}
