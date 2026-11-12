/** Comparacao de segredos em tempo constante (compara digests SHA-256 de tamanho fixo). */
export async function igualConstante(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(ha);
  const vb = new Uint8Array(hb);
  let dif = 0;
  for (let i = 0; i < va.length; i++) dif |= va[i] ^ vb[i];
  return dif === 0;
}
