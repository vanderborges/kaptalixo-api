// Edge Function planejar-rota (UC06). Ver README.md.
import { igualConstante } from "./auth.ts";
import { criarHandler } from "./handler.ts";
import { ClienteOsrmHttp, validarBaseUrl } from "./osrm.ts";
import {
  criarClienteServico,
  RepositorioRotaSupabase,
} from "./repositorio_supabase.ts";

const db = criarClienteServico();
const chaveServico = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function inteiroEnv(
  nome: string,
  padrao: number,
  min: number,
  max: number,
): number {
  const v = Number(Deno.env.get(nome));
  return Number.isFinite(v) && v >= min && v <= max ? v : padrao;
}

const osrm = new ClienteOsrmHttp({
  // Default documentado (docs/04): servidor demo publico, somente para a POC.
  baseUrl: validarBaseUrl(
    Deno.env.get("OSRM_BASE_URL") ?? "https://router.project-osrm.org",
  ),
  timeoutMs: inteiroEnv("OSRM_TIMEOUT_MS", 1500, 200, 4000),
  tentativas: 2, // 1 tentativa + 1 retry
});

Deno.serve(criarHandler({
  osrm,
  velocidadeFallbackMs: inteiroEnv("FALLBACK_VELOCIDADE_MS", 5, 1, 40),
  orcamentoMs: inteiroEnv("PLANEJAR_ORCAMENTO_MS", 2500, 500, 2800),
  repo: new RepositorioRotaSupabase(db),
  async autenticar(token) {
    if (await igualConstante(token, chaveServico)) return { tipo: "servico" };
    const { data, error } = await db.auth.getUser(token);
    if (error || !data.user) return null;
    return { tipo: "usuario", id: data.user.id };
  },
}));
