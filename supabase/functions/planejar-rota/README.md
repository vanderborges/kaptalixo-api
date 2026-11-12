# planejar-rota (UC06)

Edge Function (Deno) que monta a rota otimizada de um catador: le `rotas`,
`rota_paradas`, a posicao atual do catador e o ponto de descarte; chama o OSRM
`trip` e grava ordem, ETA, trechos, polyline, `origem_calculo` e `versao`.

## Como e disparada (decisao)

**Chamada do app logo apos `aceitar_oferta`** (nao `pg_net`).

- `aceitar_oferta` devolve o `rota_id`; o app do catador faz
  `POST /functions/v1/planejar-rota` com `{"rota_id": "<uuid>"}` e o JWT da
  sessao (`supabase.functions.invoke('planejar-rota', body: {...})`).
- Motivos: mais simples na POC (sem extensao/segredo no banco, sem fila), erros
  visiveis ao app (que mostra o aviso discreto do fallback) e testavel sem
  Postgres. Custo: se o app morrer entre aceitar e chamar, a rota fica sem ordem
  ate a proxima chamada. Mitigacao: a funcao e idempotente; o app repete a
  chamada ao abrir a rota (T5.3) e apos concluir/pular parada (recalculo, UC06).
- Migrar para `pg_net` depois e trivial: um trigger/RPC chamando esta mesma URL
  com a service role.
- A funcao tambem aceita a **service role** (jobs, painel demo, futuro
  `pg_net`).

## Contrato

`POST /functions/v1/planejar-rota` ·
`Authorization: Bearer <jwt do catador | service role>`

Entrada: `{ "rota_id": "<uuid>" }`

Saida 200:
`{ rota_id, versao, origem_calculo: "osrm"|"haversine", distancia_total_m, duracao_total_s, ordem: [parada_id|null] }`
(`null` = parada de descarte recem-criada). Nao devolve coordenadas nem
polyline: o app le `v_rota_catador` / `rota_paradas`.

| Status | `erro`                          | Quando                                   |
| ------ | ------------------------------- | ---------------------------------------- |
| 400    | `entrada_invalida`              | corpo nao e JSON ou `rota_id` nao e uuid |
| 401    | `nao_autenticado`               | sem Bearer ou token invalido             |
| 403    | `sem_permissao`                 | usuario nao e o catador dono da rota     |
| 404    | `rota_inexistente`              |                                          |
| 405    | `metodo_nao_permitido`          |                                          |
| 409    | `conflito_versao`               | rota mudou duas vezes durante o calculo  |
| 422    | `rota_invalida` / `sem_paradas` | rota encerrada / nada a planejar         |

## Algoritmo

1. Coordenadas `[P0, C1..Cn, D]`. P0 = ultima parada `no_local` (travada) ou
   `catadores.localizacao_atual`; sem posicao, parte da primeira parada
   pendente. D so existe se `rotas.ponto_destino_id` estiver definido (escolha
   do ponto = T4.3); ate la usa-se `source=first&roundtrip=false` sem
   `destination`.
2. OSRM
   `GET {OSRM_BASE_URL}/trip/v1/driving/...?source=first[&destination=last]&roundtrip=false&geometries=polyline&overview=full`.
   Timeout curto (2 s padrao, maximo 4 s), 1 retry.
3. Resposta invalida, OSRM fora, orcamento estourado ou ordem do OSRM pior que a FIFO (em linha reta): **fallback** vizinho mais proximo
   (haversine), geometria em linha reta, `origem_calculo='haversine'`. O
   fallback compara com a ordem de chegada (FIFO) e usa a de menor distancia.
   Duracao = distancia / `FALLBACK_VELOCIDADE_MS` (padrao 5 m/s, igual a
   `aceitar_oferta`).
4. Grava `ordem` (continuando depois das paradas `concluida`/`pulada`, que nao
   sao tocadas), `eta` (agora + duracao acumulada de conducao; sem tempo de
   parada), `distancia_trecho_m`, `duracao_trecho_s`, e na rota `polyline`,
   totais, `origem_calculo` e `versao = versao + 1`.
5. Bloqueio otimista: o `update` de `rotas` exige `versao` igual a lida. Se
   `aceitar_oferta` alterou a rota no meio, a funcao relê e replaneja uma vez
   (senao 409).

## Seguranca

- Autenticacao no codigo (alem do `verify_jwt` padrao do runtime): token ==
  `SUPABASE_SERVICE_ROLE_KEY` (servico) ou `auth.getUser(token)`; usuario so
  planeja rota em que `rotas.catador_id = auth.uid()`.
- Service role so via ambiente do runtime; nada no git. Logs nunca incluem
  coordenadas.

## Configuracao (ambiente)

| Variavel                                    | Padrao                            | Obs.                            |
| ------------------------------------------- | --------------------------------- | ------------------------------- |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | injetadas pelo runtime            | obrigatorias                    |
| `OSRM_BASE_URL`                             | `https://router.project-osrm.org` | servidor demo, so POC (docs/04) |
| `OSRM_TIMEOUT_MS`                           | `2000`                            | 200 a 4000                      |
| `FALLBACK_VELOCIDADE_MS`                    | `5`                               | so no fallback                  |

## Privacidade (LGPD)

Com o default, as coordenadas das paradas (enderecos de geradores) e a posicao do catador sao enviadas ao
servidor publico do OSRM, de terceiros. Aceitavel so na POC com dados ficticios; em producao, usar OSRM proprio
via `OSRM_BASE_URL`. Logs da funcao nunca incluem coordenadas nem a mensagem bruta de erros do PostgREST (so tabela e codigo).
O token da service role e comparado em tempo constante.

## Limitacoes conhecidas

- Gravacao em varias chamadas PostgREST (nao transacional); a funcao e
  idempotente, entao reexecutar corrige gravacao parcial. RPC atomica pedida em
  `backlog/PEDIDOS.md`.
- `rota_paradas` usa a ordem atual como baseline "FIFO" (nao ha timestamp de
  aceite na parada).
- Desvio > 300 m da polyline (gatilho de recalculo) fica a cargo do app/T5.x
  chamando esta funcao.

## Testes

Sem rede e sem leitura de arquivos (OSRM mockado; fixtures como modulo TS em `fixtures/osrm.ts`). Deno nao precisa estar
instalado; via docker:

```
cd repositorios/kaptalixo-api/supabase/functions/planejar-rota
docker run --rm -v "$PWD:/app" -w /app denoland/deno:latest deno test --allow-env
# com Deno local: deno test --allow-env   (mesmas flags do scripts/verificar.ps1)
```

(O unico acesso a rede e baixar `@std/assert` do JSR na primeira execucao.)
