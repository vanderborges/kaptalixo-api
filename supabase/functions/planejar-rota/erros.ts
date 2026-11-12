/** Nunca repassa e.message do PostgREST: pode conter a linha com coordenadas. So contexto/codigo. */
export function falha(contexto: string, e: { code?: string } | null): never {
  throw new Error(`${contexto}: ${e?.code ?? "erro"}`);
}
