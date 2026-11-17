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

/**
 * Ponto em EWKB hexadecimal (o que o PostgREST devolve para colunas
 * geography/geometry). Aceita endianness 00/01 e SRID opcional.
 */
export function lerEwkbHex(texto: string): Coord | null {
  const h = texto.trim();
  if (h.length < 42 || h.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(h)) {
    return null;
  }
  const bytes = new Uint8Array(h.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  }
  const dv = new DataView(bytes.buffer);
  const little = bytes[0] === 1;
  if (bytes[0] !== 0 && bytes[0] !== 1) return null;
  const tipo = dv.getUint32(1, little);
  const temSrid = (tipo & 0x20000000) !== 0;
  const base = tipo & 0x0fffffff;
  if (base !== 1) return null; // so Point
  const off = 5 + (temSrid ? 4 : 0);
  if (bytes.length < off + 16) return null;
  const lng = dv.getFloat64(off, little);
  const lat = dv.getFloat64(off + 8, little);
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
  return { lng, lat };
}

/** Interpreta geography vinda do PostgREST (GeoJSON, EWKB hex) ou texto WKT/EWKT. */
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
    const hex = lerEwkbHex(v);
    if (hex) return hex;
    const m = v.match(/POINT\s*\(\s*(-?[\d.]+)\s+(-?[\d.]+)\s*\)/i);
    if (m) return { lng: Number(m[1]), lat: Number(m[2]) };
  }
  return null;
}

export function ewkt(c: Coord): string {
  return `SRID=4326;POINT(${c.lng} ${c.lat})`;
}
