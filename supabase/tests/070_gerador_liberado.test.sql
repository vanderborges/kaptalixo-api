-- T1.8: gerador liberado apos 'coletada'. Ativas = buscando, aceita, a_caminho, no_local.
begin;
select plan(12);

create function public._g(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); set local role authenticated; end $$;
grant execute on function public._g(int), public._as(uuid) to authenticated;

insert into auth.users (id) select public._g(n) from generate_series(1, 4) n;
insert into perfis (id, papel, nome) select public._g(n), 'gerador', 'G' || n from generate_series(1, 4) n;
insert into geradores (perfil_id) select public._g(n) from generate_series(1, 4) n;
-- catador disponivel perto (lat 65), para o pedido ficar em 'buscando'
insert into auth.users (id) values (public._g(9));
insert into perfis (id, papel, nome) values (public._g(9), 'catador', 'C9');
insert into catadores (perfil_id, status_cadastro, capacidade_sacos, situacao, localizacao_atual)
values (public._g(9), 'aprovado', 10, 'disponivel', st_setsrid(st_makepoint(10, 65.001), 4326)::geography);

-- indice: so 4 estados ativos
select ok((select indexdef from pg_indexes where indexname = 'solic_uma_ativa_por_gerador') not ilike '%coletada%',
  'indice unico nao inclui coletada');
select ok((select indexdef from pg_indexes where indexname = 'solic_uma_ativa_por_gerador') ilike '%no_local%',
  'indice unico inclui no_local');

-- G1: com solicitacao coletada cria outra
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id)
values ('00000000-0000-0000-0000-0000000e1001', public._g(1), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'coletada', '1111', public._g(9));
select public._as(public._g(1));
select lives_ok($$select public.criar_solicitacao(65, 10, 'Rua Nova 1', 2)$$, 'gerador com coletada cria nova solicitacao');
select is((select count(*)::int from solicitacoes where gerador_id = public._g(1) and status = 'coletada'), 1, 'coletada segue visivel ao gerador');
select is((select count(*)::int from solicitacoes where gerador_id = public._g(1) and status = 'buscando'), 1, 'nova solicitacao em buscando');
select throws_ok($$select public.criar_solicitacao(65, 10, 'Rua Nova 2', 1)$$, 'P0001', 'solicitacao_ativa_existente',
  'duas ativas simultaneas continuam impossiveis');

-- G2: no_local continua bloqueado
reset role;
insert into solicitacoes (gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id)
values (public._g(2), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'no_local', '2222', public._g(9));
select public._as(public._g(2));
select throws_ok($$select public.criar_solicitacao(65, 10, 'Rua X', 1)$$, 'P0001', 'solicitacao_ativa_existente', 'no_local bloqueia novo pedido');

-- indice: segunda ativa por insert direto falha; coletada + ativa e coletada + coletada passam
reset role;
select throws_ok($$insert into solicitacoes (gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta)
  values (public._g(2), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'aceita', '3333')$$, '23505', null,
  'indice barra segunda ativa (no_local + aceita)');
select lives_ok($$insert into solicitacoes (gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id)
  values (public._g(3), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'coletada', '4444', public._g(9)),
         (public._g(3), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'coletada', '5555', public._g(9))$$,
  'varias coletadas coexistem');

-- G3 (duas coletadas) cria nova; G4 com cancelada cria nova
select public._as(public._g(3));
select lives_ok($$select public.criar_solicitacao(65, 10, 'Rua Y', 1)$$, 'gerador com coletadas cria nova');
-- outro gerador nao ve as coletadas de G3
select public._as(public._g(4));
select is((select count(*)::int from solicitacoes where gerador_id = public._g(3)), 0, 'outro gerador nao ve solicitacoes alheias');

-- cancelar_solicitacao de coletada segue negado (RN09)
select public._as(public._g(1));
select throws_ok($$select public.cancelar_solicitacao('00000000-0000-0000-0000-0000000e1001')$$, 'P0001', 'solicitacao_nao_cancelavel',
  'coletada nao e cancelavel');

select * from finish();
rollback;
