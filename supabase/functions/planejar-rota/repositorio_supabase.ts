import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { ewkt, lerPonto } from "./geo.ts";
import type {
  ParadaRota,
  Plano,
  RepositorioRota,
  RotaCarregada,
} from "./tipos.ts";

/** Cria o cliente com service role. A chave vem SO do ambiente do runtime. */
export function criarClienteServico(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const chave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !chave) throw new Error("ambiente_incompleto");
  return createClient(url, chave, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function falha(contexto: string, e: { message: string } | null): never {
  throw new Error(`${contexto}: ${e?.message ?? "erro"}`);
}

export class RepositorioRotaSupabase implements RepositorioRota {
  constructor(private db: SupabaseClient) {}

  async carregar(rotaId: string): Promise<RotaCarregada | null> {
    const { data: r, error: eR } = await this.db.from("rotas")
      .select("id,catador_id,status,versao,ponto_destino_id").eq("id", rotaId)
      .maybeSingle();
    if (eR) falha("rotas", eR);
    if (!r) return null;

    const { data: c, error: eC } = await this.db.from("catadores")
      .select("localizacao_atual").eq("perfil_id", r.catador_id).maybeSingle();
    if (eC) falha("catadores", eC);

    const { data: ps, error: eP } = await this.db.from("rota_paradas")
      .select("id,ordem,tipo,status,solicitacao_id,ponto_id,localizacao")
      .eq("rota_id", rotaId).order("ordem");
    if (eP) falha("rota_paradas", eP);

    let destino: RotaCarregada["destino"] = null;
    if (r.ponto_destino_id) {
      const { data: pt, error: eD } = await this.db.from("pontos_coleta")
        .select("localizacao").eq("id", r.ponto_destino_id).maybeSingle();
      if (eD) falha("pontos_coleta", eD);
      const coord = lerPonto(pt?.localizacao);
      if (coord) destino = { ponto_id: r.ponto_destino_id, coord };
    }

    const paradas: ParadaRota[] = [];
    for (const p of ps ?? []) {
      const coord = lerPonto(p.localizacao);
      if (!coord) continue;
      paradas.push({
        id: p.id,
        ordem: p.ordem,
        tipo: p.tipo,
        status: p.status,
        solicitacao_id: p.solicitacao_id,
        ponto_id: p.ponto_id,
        coord,
      });
    }
    return {
      id: r.id,
      catador_id: r.catador_id,
      status: r.status,
      versao: r.versao,
      ponto_destino_id: r.ponto_destino_id,
      origem: lerPonto(c?.localizacao_atual),
      destino,
      paradas,
    };
  }

  /**
   * Grava o plano com bloqueio otimista em rotas.versao. As escritas nao sao uma unica
   * transacao (limite do PostgREST); o plano e idempotente, entao reexecutar corrige
   * qualquer gravacao parcial. Ver README e PEDIDOS (RPC atomica).
   */
  async gravar(rota: RotaCarregada, plano: Plano): Promise<boolean> {
    const { data, error } = await this.db.from("rotas").update({
      versao: rota.versao + 1,
      polyline: plano.polyline,
      origem_calculo: plano.origem_calculo,
      distancia_total_m: plano.distancia_total_m,
      duracao_total_s: plano.duracao_total_s,
    }).eq("id", rota.id).eq("versao", rota.versao)
      .in("status", ["planejada", "em_andamento"]).select("id");
    if (error) falha("rotas.update", error);
    if (!data || data.length === 0) return false;

    for (const p of plano.paradas) {
      const comum = {
        ordem: p.ordem,
        eta: p.eta,
        distancia_trecho_m: p.distancia_trecho_m,
        duracao_trecho_s: p.duracao_trecho_s,
      };
      if (p.id === null) {
        const { error: e } = await this.db.from("rota_paradas").insert({
          ...comum,
          rota_id: rota.id,
          tipo: "descarte",
          ponto_id: p.ponto_id,
          localizacao: ewkt(p.coord),
        });
        if (e) falha("rota_paradas.insert", e);
      } else {
        const extra = p.tipo === "descarte"
          ? { ponto_id: p.ponto_id, localizacao: ewkt(p.coord) }
          : {};
        const { error: e } = await this.db.from("rota_paradas")
          .update({ ...comum, ...extra }).eq("id", p.id).eq("rota_id", rota.id);
        if (e) falha("rota_paradas.update", e);
      }
    }
    return true;
  }
}
