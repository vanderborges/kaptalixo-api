# kaptalixo-api

API do Kaptalixo: projeto Supabase (Postgres/PostGIS, RLS, RPCs, Edge Functions, pgTAP).
Comandos: `supabase db reset` e `supabase test db` (use `--workdir repositorios/kaptalixo-api` a partir da raiz).

## Painel de demonstracao (T1.6, UC15/UC16)

Migration `20260101001000_demo_backend.sql`. Todas as RPCs `demo_*` e `resetar_demo` exigem admin
(`sem_permissao`) e `parametros.modo_demo = true` (`modo_demo_desativado`); `security definer` com
`search_path` explicito; execute so para `authenticated`; nunca devolvem `pin_coleta`.

| RPC | Retorno | Erros |
| --- | --- | --- |
| `demo_snapshot(p_eventos int default 50)` | jsonb (abaixo) | `parametro_invalido` (p_eventos fora de 1..200) |
| `demo_criar_catadores(p_n int)` | int (quantos criou, 1..20) | `parametro_invalido` |
| `demo_criar_pedido()` | uuid da solicitacao (dispara o matching) | `sem_gerador_livre` |
| `demo_mover_catador(p_catador uuid, p_lat float8, p_lng float8)` | void | `parametro_invalido`, `catador_nao_ficticio` |
| `resetar_demo()` | void (medido: ~10 ms com 20 catadores demo + 5 pedidos) | |

"Ficticio" = linha em `demo_atores` (sem grants): geradores/catadores do seed (`origem='seed'`) e catadores criados por
`demo_criar_catadores` (`origem='demo'`, contas sem senha em `@demo.kaptalixo.local`; `resetar_demo` as remove).
`demo_criar_pedido` so usa geradores ficticios sem pedido ativo.

### JSON de `demo_snapshot` (lido por `SnapshotDemo.fromJson` no kaptalixo-web)

```json
{
  "atores": [{"id": "uuid", "tipo": "gerador|catador|ponto", "nome": "text", "lat": 0.0, "lng": 0.0,
              "situacao": "disponivel|em_rota|offline (catador) | null"}],
  "rotas": [{"id": "uuid", "catador_id": "uuid", "status": "planejada|em_andamento", "polyline": "codificada ou null",
             "paradas": [{"ordem": 1, "tipo": "coleta|descarte", "status": "pendente|...", "lat": 0.0, "lng": 0.0}]}],
  "eventos": [{"id": 1, "solicitacao_id": "uuid", "tipo": "= para_status", "de_status": "text|null",
               "para_status": "text", "criado_em": "timestamptz ISO 8601"}]
}
```

Atores: geradores (endereco padrao), catadores aprovados com posicao, pontos ativos. Rotas: so abertas. Eventos: mais
recentes primeiro, no maximo `p_eventos`.

## Outras RPCs/visoes da T1.6

- `pontos_proximos(p_lat, p_lng, p_raio_m)` -> `id, nome, lat, lng, distancia_m, aberto` (pontos ativos, raio ate 100 km,
  max. 20, mais proximos primeiro; sem telefone/operador; `aberto` no fuso America/Sao_Paulo).
- `v_entrega_a_caminho` -> `rota_id, ponto_id, catador_nome, qtd_sacos, eta, chegou`: so rotas `em_andamento` cujo destino
  e o ponto do operador (`opera_ponto`); sem dados de geradores.
