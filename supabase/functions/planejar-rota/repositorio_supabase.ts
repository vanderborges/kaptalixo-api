import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { falha } from "./erros.ts";
import { ewkt, lerPonto } from "./geo.ts";
import type {
  ContextoDescarte,
  Horario,
  ParadaRota,
  Plano,
  PontoCandidato,
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
    const temColeta = paradas.some((p) => p.tipo === "coleta");
    const contexto_descarte = !r.ponto_destino_id && temColeta
      ? await this.carregarContextoDescarte(paradas)
      : null;
    return {
      id: r.id,
      catador_id: r.catador_id,
      status: r.status,
      versao: r.versao,
      ponto_destino_id: r.ponto_destino_id,
      origem: lerPonto(c?.localizacao_atual),
      destino,
      paradas,
      contexto_descarte,
    };
  }

  /** Dados do UC07: parametros (RN06/RN07), solicitacoes da rota, pontos ativos e precos. */
  private async carregarContextoDescarte(
    paradas: ParadaRota[],
  ): Promise<ContextoDescarte> {
    const { data: pars, error: eA } = await this.db.from("parametros")
      .select("chave,valor").in("chave", ["custo_km_reais", "peso_saco_kg"]);
    if (eA) falha("parametros", eA);
    const par = new Map((pars ?? []).map((p) => [p.chave, p.valor]));
    const custo = Number(par.get("custo_km_reais"));
    if (!Number.isFinite(custo) || custo < 0) {
      throw new Error("parametro_custo_km_invalido");
    }
    const pesoSaco = (par.get("peso_saco_kg") ?? {}) as Record<string, number>;

    const solIds = [
      ...new Set(
        paradas.filter((p) =>
          p.tipo === "coleta" && p.status !== "pulada" && p.solicitacao_id
        )
          .map((p) => p.solicitacao_id as string),
      ),
    ];
    let coletas: ContextoDescarte["coletas"] = [];
    if (solIds.length > 0) {
      const { data: ss, error: eS } = await this.db.from("solicitacoes")
        .select("id,qtd_sacos,tamanho,peso_estimado_kg").in("id", solIds);
      if (eS) falha("solicitacoes", eS);
      const { data: ms, error: eM } = await this.db.from(
        "solicitacao_materiais",
      )
        .select("solicitacao_id,material_id").in("solicitacao_id", solIds);
      if (eM) falha("solicitacao_materiais", eM);
      const mats = new Map<string, number[]>();
      for (const m of ms ?? []) {
        mats.set(m.solicitacao_id, [
          ...(mats.get(m.solicitacao_id) ?? []),
          m.material_id,
        ]);
      }
      coletas = (ss ?? []).map((s) => ({
        // RN07: peso estimado da solicitacao; senao sacos x peso do tamanho.
        peso_kg: Number(
          s.peso_estimado_kg ?? s.qtd_sacos * (pesoSaco[s.tamanho] ?? 5),
        ),
        materiais: mats.get(s.id) ?? [],
      }));
    }

    const { data: pts, error: eP } = await this.db.from("pontos_coleta")
      .select("id,localizacao,horario_funcionamento").eq("ativo", true);
    if (eP) falha("pontos_coleta", eP);
    const ids = (pts ?? []).map((p) => p.id);
    const precos = new Map<string, Record<number, number>>();
    if (ids.length > 0) {
      const { data: pr, error: eR } = await this.db.from("ponto_precos")
        .select("ponto_id,material_id,preco_kg").in("ponto_id", ids);
      if (eR) falha("ponto_precos", eR);
      for (const x of pr ?? []) {
        const o = precos.get(x.ponto_id) ?? {};
        o[x.material_id] = Number(x.preco_kg);
        precos.set(x.ponto_id, o);
      }
    }
    const pontos: PontoCandidato[] = [];
    for (const p of pts ?? []) {
      const coord = lerPonto(p.localizacao);
      if (!coord) continue;
      pontos.push({
        id: p.id,
        coord,
        horario: (p.horario_funcionamento ?? {}) as Horario,
        precos: precos.get(p.id) ?? {},
      });
    }
    return { custo_km: custo, coletas, pontos };
  }

  /**
   * Grava o plano com bloqueio otimista em rotas.versao. As escritas nao sao uma unica
   * transacao (limite do PostgREST); o plano e idempotente, entao reexecutar corrige
   * qualquer gravacao parcial. Ver README e PEDIDOS (RPC atomica).
   */
  async gravar(rota: RotaCarregada, plano: Plano): Promise<boolean> {
    const { data, error } = await this.db.from("rotas").update({
      // UC07: so presentes quando a funcao escolheu o ponto agora (ponto_destino_id era null).
      ...(plano.ponto_destino_id
        ? {
          ponto_destino_id: plano.ponto_destino_id,
          alternativas_ponto: plano.alternativas_ponto ?? [],
        }
        : {}),
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
