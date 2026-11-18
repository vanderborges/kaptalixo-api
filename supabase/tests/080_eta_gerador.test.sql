-- T1.9: eta e distancia_trecho_m da parada de coleta na v_solicitacao_gerador.
begin;
select plan(9);

create function public._g(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000f0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); set local role authenticated; end $$;
grant execute on function public._g(int), public._as(uuid) to authenticated;

insert into auth.users (id) select public._g(n) from generate_series(1, 3) n;
insert into perfis (id, papel, nome) select public._g(n), 'gerador', 'G' || n from generate_series(1, 3) n;
insert into geradores (perfil_id) select public._g(n) from generate_series(1, 3) n;
insert into auth.users (id) values (public._g(9));
insert into perfis (id, papel, nome) values (public._g(9), 'catador', 'C9');
insert into catadores (perfil_id, status_cadastro, capacidade_sacos, situacao)
values (public._g(9), 'aprovado', 10, 'em_rota');

-- G1: aceita (com ETA) ; G2: aceita (outro ETA) ; G3: coletada antiga + nova buscando
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id) values
 ('00000000-0000-0000-0000-0000000f1001', public._g(1), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'aceita', '1111', public._g(9)),
 ('00000000-0000-0000-0000-0000000f1002', public._g(2), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'aceita', '2222', public._g(9)),
 ('00000000-0000-0000-0000-0000000f1003', public._g(3), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'coletada', '3333', public._g(9));
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta)
values ('00000000-0000-0000-0000-0000000f1004', public._g(3), st_setsrid(st_makepoint(10, 65), 4326)::geography, 1, 'M', 5, 'buscando', '4444');

insert into rotas (id, catador_id, status) values ('00000000-0000-0000-0000-0000000f2001', public._g(9), 'em_andamento');
insert into rota_paradas (rota_id, ordem, tipo, solicitacao_id, localizacao, status, eta, distancia_trecho_m) values
 ('00000000-0000-0000-0000-0000000f2001', 1, 'coleta', '00000000-0000-0000-0000-0000000f1001', st_setsrid(st_makepoint(10, 65), 4326)::geography, 'pendente', '2030-01-01 10:00:00+00', 1234),
 ('00000000-0000-0000-0000-0000000f2001', 2, 'coleta', '00000000-0000-0000-0000-0000000f1002', st_setsrid(st_makepoint(10, 65), 4326)::geography, 'pendente', '2030-01-01 10:20:00+00', 5678),
 ('00000000-0000-0000-0000-0000000f2001', 3, 'coleta', '00000000-0000-0000-0000-0000000f1003', st_setsrid(st_makepoint(10, 65), 4326)::geography, 'concluida', '2030-01-01 09:00:00+00', 999);

-- G1 ve so o proprio ETA
select public._as(public._g(1));
select is((select count(*)::int from v_solicitacao_gerador), 1, 'G1 ve apenas a propria solicitacao');
select is((select eta from v_solicitacao_gerador), '2030-01-01 10:00:00+00'::timestamptz, 'G1 ve eta da propria parada');
select is((select distancia_trecho_m from v_solicitacao_gerador), 1234, 'G1 ve distancia do proprio trecho');

-- G2 ve o dele, nao o de G1
select public._as(public._g(2));
select is((select eta from v_solicitacao_gerador), '2030-01-01 10:20:00+00'::timestamptz, 'G2 ve o proprio eta');
select is((select count(*)::int from v_solicitacao_gerador where id = '00000000-0000-0000-0000-0000000f1001'), 0, 'G2 nao ve solicitacao de G1');

-- G3: coletada (parada concluida) + buscando: 2 linhas, ambas sem eta
select public._as(public._g(3));
select is((select count(*)::int from v_solicitacao_gerador), 2, 'G3 mantem 2 linhas (coletada + nova)');
select is((select count(*)::int from v_solicitacao_gerador where eta is not null or distancia_trecho_m is not null), 0,
  'sem eta em coletada/buscando');

-- anon sem acesso; a view nao expoe colunas de outras paradas
select public._as(public._g(1));
select is((select count(*)::int from information_schema.columns where table_name = 'v_solicitacao_gerador' and column_name in ('eta', 'distancia_trecho_m')), 2,
  'view expoe eta e distancia_trecho_m');
reset role;
set local role anon;
select throws_ok($$select * from public.v_solicitacao_gerador$$, '42501', null, 'anon sem acesso a view');

select * from finish();
rollback;
