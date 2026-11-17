-- T1.6: backend da demo (demo_snapshot, demo_criar_catadores, demo_criar_pedido, demo_mover_catador,
-- resetar_demo), pontos_proximos, v_entrega_a_caminho, Realtime e grants pedidos em P-019..P-023.
-- Autonomo: fixtures proprias (lat 55..57) dentro da transacao; demo_atores e zerada para controlar quem e ficticio.
begin;
select plan(114);

-- ---------- fixtures ----------
create function public._u(prefixo text, n int) returns uuid language sql immutable as
$$ select (prefixo || '-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function public._claim(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform public._claim(p); set local role authenticated; end $$;
grant execute on function public._u(text, int), public._claim(uuid), public._as(uuid) to authenticated;

-- 1 admin, 4 geradores (1 = ficticio com endereco), 2 catadores (1 ficticio, 1 real), 2 operadores de ponto
insert into auth.users (id) select public._u('a1000000', n) from generate_series(1, 9) n;
insert into perfis (id, papel, nome) values
  (public._u('a1000000', 1), 'admin',   'Adm'),
  (public._u('a1000000', 2), 'gerador', 'Ger Ficticio'),
  (public._u('a1000000', 3), 'gerador', 'Ger Real 3'),
  (public._u('a1000000', 4), 'gerador', 'Ger Real 4'),
  (public._u('a1000000', 5), 'catador', 'Cat Ficticio'),
  (public._u('a1000000', 6), 'catador', 'Cat Real'),
  (public._u('a1000000', 7), 'ponto',   'Op 1'),
  (public._u('a1000000', 8), 'ponto',   'Op 2');
insert into enderecos (id, perfil_id, logradouro, numero, cidade, uf, localizacao) values
  (public._u('a2000000', 2), public._u('a1000000', 2), 'Rua Demo', '10', 'X', 'SP',
   st_setsrid(st_makepoint(10, 55), 4326)::geography);
insert into geradores (perfil_id, endereco_padrao_id) values
  (public._u('a1000000', 2), public._u('a2000000', 2)),
  (public._u('a1000000', 3), null),
  (public._u('a1000000', 4), null);
insert into catadores (perfil_id, status_cadastro, capacidade_sacos, situacao, localizacao_atual) values
  (public._u('a1000000', 5), 'aprovado', 10, 'disponivel', st_setsrid(st_makepoint(10, 55.001), 4326)::geography),
  (public._u('a1000000', 6), 'aprovado', 10, 'em_rota',    st_setsrid(st_makepoint(10, 55.5), 4326)::geography);
insert into pontos_coleta (id, perfil_id, nome, logradouro, cidade, uf, telefone, localizacao, horario_funcionamento, ativo) values
  (public._u('a3000000', 1), public._u('a1000000', 7), 'Ponto 1', 'R1', 'X', 'SP', '11999990001',
   st_setsrid(st_makepoint(10, 56.001), 4326)::geography,
   '{"seg":[["00:00","24:00"]],"ter":[["00:00","24:00"]],"qua":[["00:00","24:00"]],"qui":[["00:00","24:00"]],"sex":[["00:00","24:00"]],"sab":[["00:00","24:00"]],"dom":[["00:00","24:00"]]}', true),
  (public._u('a3000000', 2), public._u('a1000000', 8), 'Ponto 2', 'R2', 'X', 'SP', '11999990002',
   st_setsrid(st_makepoint(10, 56.002), 4326)::geography, '{}', true),
  (public._u('a3000000', 3), null, 'Ponto inativo', 'R3', 'X', 'SP', null,
   st_setsrid(st_makepoint(10, 56.0005), 4326)::geography, '{}', false),
  (public._u('a3000000', 4), null, 'Ponto longe', 'R4', 'X', 'SP', null,
   st_setsrid(st_makepoint(10, 56.5), 4326)::geography, '{}', true);

-- so o gerador 2 e o catador 5 sao ficticios
delete from demo_atores where true;
insert into demo_atores (perfil_id, origem) values
  (public._u('a1000000', 2), 'seed'), (public._u('a1000000', 5), 'seed');
insert into parametros (chave, valor) values ('modo_demo', 'true'::jsonb)
  on conflict (chave) do update set valor = 'true'::jsonb;

-- ---------- permissoes de funcao ----------
select ok(has_function_privilege('authenticated', 'public.demo_snapshot(int)', 'execute'), 'authenticated executa demo_snapshot');
select ok(has_function_privilege('authenticated', 'public.demo_criar_catadores(int)', 'execute'), 'authenticated executa demo_criar_catadores');
select ok(has_function_privilege('authenticated', 'public.demo_criar_pedido()', 'execute'), 'authenticated executa demo_criar_pedido');
select ok(has_function_privilege('authenticated', 'public.demo_mover_catador(uuid,float8,float8)', 'execute'), 'authenticated executa demo_mover_catador');
select ok(has_function_privilege('authenticated', 'public.pontos_proximos(float8,float8,float8)', 'execute'), 'authenticated executa pontos_proximos');
select ok(not has_function_privilege('anon', 'public.demo_snapshot(int)', 'execute'), 'anon nao executa demo_snapshot');
select ok(not has_function_privilege('anon', 'public.demo_criar_catadores(int)', 'execute'), 'anon nao executa demo_criar_catadores');
select ok(not has_function_privilege('anon', 'public.demo_criar_pedido()', 'execute'), 'anon nao executa demo_criar_pedido');
select ok(not has_function_privilege('anon', 'public.demo_mover_catador(uuid,float8,float8)', 'execute'), 'anon nao executa demo_mover_catador');
select ok(not has_function_privilege('anon', 'public.pontos_proximos(float8,float8,float8)', 'execute'), 'anon nao executa pontos_proximos');
select ok(not has_function_privilege('authenticated', 'public._demo_guarda()', 'execute'), 'helper _demo_guarda e interno');
select ok(not has_function_privilege('authenticated', 'public._ponto_aberto(jsonb,timestamptz)', 'execute'), 'helper _ponto_aberto e interno');
select ok(not has_table_privilege('authenticated', 'public.demo_atores', 'select'), 'authenticated nao le demo_atores');
select ok(not has_table_privilege('anon', 'public.demo_atores', 'select'), 'anon nao le demo_atores');
select ok(not has_table_privilege('anon', 'public.v_entrega_a_caminho', 'select'), 'anon nao le v_entrega_a_caminho');
select ok(has_table_privilege('authenticated', 'public.v_entrega_a_caminho', 'select'), 'authenticated le v_entrega_a_caminho');
select ok(array_to_string(proconfig, ',') like '%search_path%', 'demo_snapshot com search_path explicito')
  from pg_proc where oid = 'public.demo_snapshot(int)'::regprocedure;
select ok(prosecdef, 'demo_mover_catador e security definer')
  from pg_proc where oid = 'public.demo_mover_catador(uuid,float8,float8)'::regprocedure;

-- ---------- permissao negada: nao-admin e sem login ----------
select public._as(public._u('a1000000', 2));   -- gerador
select throws_ok($$select public.demo_snapshot()$$, 'P0001', 'sem_permissao', 'gerador nao ve demo_snapshot');
select throws_ok($$select public.demo_criar_catadores(1)$$, 'P0001', 'sem_permissao', 'gerador nao cria catadores demo');
select throws_ok($$select public.demo_criar_pedido()$$, 'P0001', 'sem_permissao', 'gerador nao cria pedido demo');
select throws_ok(format($$select public.demo_mover_catador(%L, 55, 10)$$, public._u('a1000000', 5)), 'P0001', 'sem_permissao', 'gerador nao move catador');
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'sem_permissao', 'gerador nao reseta demo');
reset role; select public._as(public._u('a1000000', 5));   -- catador
select throws_ok($$select public.demo_snapshot()$$, 'P0001', 'sem_permissao', 'catador nao ve demo_snapshot');
reset role; select public._as(public._u('a1000000', 7));   -- ponto
select throws_ok($$select public.demo_criar_catadores(1)$$, 'P0001', 'sem_permissao', 'ponto nao cria catadores demo');
reset role; select public._claim(null);
select throws_ok($$select public.demo_snapshot()$$, 'P0001', 'sem_permissao', 'sem login nao ve demo_snapshot');
select throws_ok($$select public.pontos_proximos(56, 10, 1000)$$, 'P0001', 'sem_permissao', 'sem login nao consulta pontos_proximos');

-- ---------- modo_demo desligado ----------
reset role; update parametros set valor = 'false'::jsonb where chave = 'modo_demo';
select public._as(public._u('a1000000', 1));
select throws_ok($$select public.demo_snapshot()$$, 'P0001', 'modo_demo_desativado', 'modo_demo off: demo_snapshot negado');
select throws_ok($$select public.demo_criar_catadores(1)$$, 'P0001', 'modo_demo_desativado', 'modo_demo off: demo_criar_catadores negado');
select throws_ok($$select public.demo_criar_pedido()$$, 'P0001', 'modo_demo_desativado', 'modo_demo off: demo_criar_pedido negado');
select throws_ok(format($$select public.demo_mover_catador(%L, 55, 10)$$, public._u('a1000000', 5)), 'P0001', 'modo_demo_desativado', 'modo_demo off: demo_mover_catador negado');
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'modo_demo_desativado', 'modo_demo off: resetar_demo negado');
reset role; update parametros set valor = 'true'::jsonb where chave = 'modo_demo';

-- ---------- entradas invalidas ----------
select public._as(public._u('a1000000', 1));
select throws_ok($$select public.demo_criar_catadores(0)$$, 'P0001', 'parametro_invalido', 'demo_criar_catadores(0) invalido');
select throws_ok($$select public.demo_criar_catadores(21)$$, 'P0001', 'parametro_invalido', 'demo_criar_catadores(21) invalido');
select throws_ok($$select public.demo_criar_catadores(null)$$, 'P0001', 'parametro_invalido', 'demo_criar_catadores(null) invalido');
select throws_ok($$select public.demo_snapshot(0)$$, 'P0001', 'parametro_invalido', 'demo_snapshot(0) invalido');
select throws_ok($$select public.demo_snapshot(201)$$, 'P0001', 'parametro_invalido', 'demo_snapshot(201) invalido');
select throws_ok(format($$select public.demo_mover_catador(%L, 91, 10)$$, public._u('a1000000', 5)), 'P0001', 'parametro_invalido', 'latitude fora do intervalo');
select throws_ok(format($$select public.demo_mover_catador(%L, 55, 181)$$, public._u('a1000000', 5)), 'P0001', 'parametro_invalido', 'longitude fora do intervalo');

-- ---------- demo_criar_catadores ----------
select is(public.demo_criar_catadores(3), 3, 'demo_criar_catadores devolve a quantidade criada');
reset role;
select is((select count(*)::int from demo_atores where origem = 'demo'), 3, '3 atores demo registrados');
select is((select count(*)::int from catadores c join demo_atores d on d.perfil_id = c.perfil_id
            where d.origem = 'demo' and c.status_cadastro = 'aprovado' and c.situacao = 'disponivel'
              and c.localizacao_atual is not null), 3, 'ficticios nascem aprovados, disponiveis e com posicao');
select is((select count(*)::int from auth.users u join demo_atores d on d.perfil_id = u.id
            where d.origem = 'demo' and u.email like '%@demo.kaptalixo.local'), 3, 'contas demo no dominio de demonstracao');

-- ---------- demo_criar_pedido ----------
select public._as(public._u('a1000000', 1));
create temp table t_pedido as select public.demo_criar_pedido() as id;
grant select on t_pedido to authenticated;
reset role;
select ok((select id from t_pedido) is not null, 'demo_criar_pedido devolve o id');
select is((select gerador_id from solicitacoes where id = (select id from t_pedido)), public._u('a1000000', 2), 'pedido e do gerador ficticio');
select ok((select status from solicitacoes where id = (select id from t_pedido)) in ('buscando', 'sem_catador'), 'pedido entra no matching');
select ok((select count(*) from ofertas where solicitacao_id = (select id from t_pedido)) >= 1, 'matching gerou oferta ao catador proximo');
select public._as(public._u('a1000000', 1));
select throws_ok($$select public.demo_criar_pedido()$$, 'P0001', 'sem_gerador_livre', 'sem gerador ficticio livre');

-- ---------- demo_mover_catador ----------
select lives_ok(format($$select public.demo_mover_catador(%L, 55.01, 10.02)$$, public._u('a1000000', 5)), 'move catador ficticio');
reset role;
select is((select round(st_y(localizacao_atual::geometry)::numeric, 3) from catadores where perfil_id = public._u('a1000000', 5)), 55.010, 'latitude atualizada');
select is((select round(st_x(localizacao_atual::geometry)::numeric, 3) from catadores where perfil_id = public._u('a1000000', 5)), 10.020, 'longitude atualizada');
select is((select count(*)::int from localizacoes_catador where catador_id = public._u('a1000000', 5)), 1, 'historico gravado');
select public._as(public._u('a1000000', 1));
select throws_ok(format($$select public.demo_mover_catador(%L, 55, 10)$$, public._u('a1000000', 6)), 'P0001', 'catador_nao_ficticio', 'catador real nao pode ser movido');
select throws_ok(format($$select public.demo_mover_catador(%L, 55, 10)$$, public._u('a1000000', 2)), 'P0001', 'catador_nao_ficticio', 'gerador nao e alvo valido');
select throws_ok($$select public.demo_mover_catador('00000000-0000-0000-0000-000000000099', 55, 10)$$, 'P0001', 'catador_nao_ficticio', 'id inexistente');
select throws_ok($$select public.demo_mover_catador(null, 55, 10)$$, 'P0001', 'catador_nao_ficticio', 'id nulo');
reset role;
select is((select round(st_y(localizacao_atual::geometry)::numeric, 1) from catadores where perfil_id = public._u('a1000000', 6)), 55.5, 'catador real manteve a posicao');

-- ---------- demo_snapshot: formato ----------
-- rota aberta do catador ficticio com polyline e 2 paradas (coleta + descarte)
insert into rotas (id, catador_id, status, ponto_destino_id, polyline)
values (public._u('a4000000', 1), public._u('a1000000', 5), 'planejada', public._u('a3000000', 1), '_p~iF~ps|U_ulLnnqC');
insert into rota_paradas (rota_id, ordem, tipo, solicitacao_id, localizacao, status)
values (public._u('a4000000', 1), 1, 'coleta', (select id from t_pedido), st_setsrid(st_makepoint(10, 55), 4326)::geography, 'pendente');
insert into rota_paradas (rota_id, ordem, tipo, ponto_id, localizacao, status)
values (public._u('a4000000', 1), 2, 'descarte', public._u('a3000000', 1), st_setsrid(st_makepoint(10, 56.001), 4326)::geography, 'pendente');

select public._as(public._u('a1000000', 1));
create temp table t_snap as select public.demo_snapshot(50) as j;
grant select on t_snap to authenticated;
select is((select jsonb_typeof(j) from t_snap), 'object', 'snapshot e objeto');
select ok((select j ?& array['atores','rotas','eventos'] from t_snap), 'snapshot tem atores, rotas e eventos');
select is((select jsonb_typeof(j -> 'atores') from t_snap), 'array', 'atores e array');
select is((select jsonb_typeof(j -> 'rotas') from t_snap), 'array', 'rotas e array');
select is((select jsonb_typeof(j -> 'eventos') from t_snap), 'array', 'eventos e array');
select is((select count(*)::int from t_snap, jsonb_array_elements(j -> 'atores') a
            where a ->> 'tipo' = 'catador' and a ->> 'id' = public._u('a1000000', 5)::text
              and jsonb_typeof(a -> 'lat') = 'number' and jsonb_typeof(a -> 'lng') = 'number'
              and a ->> 'situacao' = 'disponivel' and a ->> 'nome' = 'Cat Ficticio'), 1, 'ator catador com id, nome, lat, lng e situacao');
select is((select count(*)::int from t_snap, jsonb_array_elements(j -> 'atores') a
            where a ->> 'tipo' = 'gerador' and a ->> 'id' = public._u('a1000000', 2)::text
              and jsonb_typeof(a -> 'lat') = 'number'), 1, 'ator gerador com posicao do endereco padrao');
select is((select count(*)::int from t_snap, jsonb_array_elements(j -> 'atores') a
            where a ->> 'tipo' = 'ponto' and a ->> 'id' = public._u('a3000000', 1)::text), 1, 'ator ponto ativo');
select is((select count(*)::int from t_snap, jsonb_array_elements(j -> 'atores') a
            where a ->> 'id' = public._u('a3000000', 3)::text), 0, 'ponto inativo fora do snapshot');
select is((select count(*)::int from t_snap, jsonb_array_elements(j -> 'atores') a
            where a ->> 'tipo' not in ('gerador','catador','ponto')), 0, 'tipos de ator validos para o parser');
select is((select count(*)::int from t_snap, jsonb_array_elements(j -> 'rotas') r
            where r ->> 'id' = public._u('a4000000', 1)::text and r ->> 'catador_id' = public._u('a1000000', 5)::text
              and r ->> 'status' = 'planejada' and r ->> 'polyline' = '_p~iF~ps|U_ulLnnqC'
              and jsonb_array_length(r -> 'paradas') = 2), 1, 'rota com polyline e 2 paradas');
select is((select (r -> 'paradas' -> 0 ->> 'tipo') || ':' || jsonb_typeof(r -> 'paradas' -> 0 -> 'lat') || ':' || jsonb_typeof(r -> 'paradas' -> 1 -> 'lng')
             from t_snap, jsonb_array_elements(j -> 'rotas') r where r ->> 'id' = public._u('a4000000', 1)::text),
          'coleta:number:number', 'paradas em ordem, com lat/lng numericos');
select ok((select count(*) from t_snap, jsonb_array_elements(j -> 'eventos') e
            where e ->> 'solicitacao_id' = (select id::text from t_pedido) and e ->> 'para_status' is not null
              and e ? 'de_status' and e ? 'criado_em' and jsonb_typeof(e -> 'id') = 'number') >= 1,
          'evento do pedido com id numerico, de_status, para_status e criado_em');
select is((select (j -> 'eventos' -> 0 ->> 'tipo') = (j -> 'eventos' -> 0 ->> 'para_status') from t_snap), true, 'tipo repete para_status');
select ok((select (select max((e ->> 'criado_em')::timestamptz) from jsonb_array_elements(j -> 'eventos') e)
                  = ((j -> 'eventos' -> 0) ->> 'criado_em')::timestamptz from t_snap), 'eventos mais recentes primeiro');
select is((select jsonb_array_length(public.demo_snapshot(1) -> 'eventos')), 1, 'p_eventos limita o feed');
select ok((select position('pin' in lower(j::text)) = 0 from t_snap), 'snapshot nao expoe pin_coleta');

-- ---------- pontos_proximos ----------
select public._as(public._u('a1000000', 3));   -- gerador qualquer
select is((select array_agg(id order by distancia_m) from public.pontos_proximos(56, 10, 5000)),
          array[public._u('a3000000', 1), public._u('a3000000', 2)], 'so pontos ativos no raio, do mais proximo ao mais longe');
select is((select array_agg(id order by distancia_m) from public.pontos_proximos(56, 10, 100000)),
          array[public._u('a3000000', 1), public._u('a3000000', 2), public._u('a3000000', 4)], 'raio maior inclui o ponto distante');
select is((select count(*)::int from public.pontos_proximos(56, 10, 100)), 0, 'raio curto: nenhum ponto');
select is((select aberto from public.pontos_proximos(56, 10, 5000) where id = public._u('a3000000', 1)), true, 'ponto 24h esta aberto');
select is((select aberto from public.pontos_proximos(56, 10, 5000) where id = public._u('a3000000', 2)), false, 'ponto sem horario esta fechado');
select ok((select distancia_m between 100 and 120 from public.pontos_proximos(56, 10, 5000) where id = public._u('a3000000', 1)), 'distancia em metros (~111 m)');
select is((select array_agg(c::text order by o) from unnest((select proargnames from pg_proc
            where oid = 'public.pontos_proximos(float8,float8,float8)'::regprocedure)) with ordinality as x(c, o)
            where c in ('telefone', 'perfil_id', 'operador')), null, 'pontos_proximos nao expoe telefone/operador');
select throws_ok($$select * from public.pontos_proximos(91, 10, 1000)$$, 'P0001', 'parametro_invalido', 'latitude invalida');
select throws_ok($$select * from public.pontos_proximos(56, 10, 0)$$, 'P0001', 'parametro_invalido', 'raio zero invalido');
select throws_ok($$select * from public.pontos_proximos(56, 10, 100001)$$, 'P0001', 'parametro_invalido', 'raio acima do limite invalido');
select throws_ok($$select * from public.pontos_proximos(null, 10, 1000)$$, 'P0001', 'parametro_invalido', 'parametro nulo invalido');

-- _ponto_aberto: segunda-feira 2026-11-16 (fuso America/Sao_Paulo, -03)
reset role;
select is(public._ponto_aberto('{"seg":[["08:00","17:00"]]}', '2026-11-16 12:00:00-03'), true, '_ponto_aberto: dentro do horario');
select is(public._ponto_aberto('{"seg":[["08:00","17:00"]]}', '2026-11-16 17:00:00-03'), false, '_ponto_aberto: fim exclusivo');
select is(public._ponto_aberto('{"seg":[["08:00","17:00"]]}', '2026-11-17 12:00:00-03'), false, '_ponto_aberto: dia sem horario');
select is(public._ponto_aberto('{"seg":[["22:00","02:00"]]}', '2026-11-16 23:30:00-03'), true, '_ponto_aberto: intervalo ate a meia-noite');
select is(public._ponto_aberto('{"seg":"x"}', '2026-11-16 12:00:00-03'), false, '_ponto_aberto: dado invalido = fechado');

-- ---------- v_entrega_a_caminho ----------
insert into solicitacoes (id, gerador_id, localizacao, endereco_texto, qtd_sacos, status, pin_coleta, catador_id) values
  (public._u('a5000000', 1), public._u('a1000000', 3), st_setsrid(st_makepoint(10, 58), 4326)::geography, 'Rua Secreta 1', 3, 'coletada', '1234', public._u('a1000000', 6)),
  (public._u('a5000000', 2), public._u('a1000000', 4), st_setsrid(st_makepoint(10, 58.1), 4326)::geography, 'Rua Secreta 2', 2, 'a_caminho', '4321', public._u('a1000000', 6)),
  (public._u('a5000000', 3), public._u('a1000000', 4), st_setsrid(st_makepoint(10, 58.2), 4326)::geography, 'Rua Secreta 3', 9, 'cancelada', '1111', null);
insert into rotas (id, catador_id, status, ponto_destino_id)
values (public._u('a4000000', 2), public._u('a1000000', 6), 'em_andamento', public._u('a3000000', 1));
insert into rota_paradas (rota_id, ordem, tipo, solicitacao_id, localizacao, status) values
  (public._u('a4000000', 2), 1, 'coleta', public._u('a5000000', 1), st_setsrid(st_makepoint(10, 58), 4326)::geography, 'concluida'),
  (public._u('a4000000', 2), 2, 'coleta', public._u('a5000000', 2), st_setsrid(st_makepoint(10, 58.1), 4326)::geography, 'a_caminho'),
  (public._u('a4000000', 2), 3, 'coleta', public._u('a5000000', 3), st_setsrid(st_makepoint(10, 58.2), 4326)::geography, 'pulada');
insert into rota_paradas (rota_id, ordem, tipo, ponto_id, localizacao, status, eta)
values (public._u('a4000000', 2), 4, 'descarte', public._u('a3000000', 1), st_setsrid(st_makepoint(10, 56.001), 4326)::geography, 'pendente', now() + interval '10 minutes');

select public._as(public._u('a1000000', 7));   -- operador do ponto 1
select is((select count(*)::int from v_entrega_a_caminho), 1, 'operador ve a entrega a caminho do seu ponto');
select is((select qtd_sacos from v_entrega_a_caminho), 5, 'soma sacos das coletas nao puladas');
select is((select catador_nome from v_entrega_a_caminho), 'Cat Real', 'nome do catador');
select is((select chegou from v_entrega_a_caminho), false, 'ainda nao chegou');
select ok((select eta > now() from v_entrega_a_caminho), 'eta da parada de descarte');
select is((select array_agg(column_name::text order by ordinal_position) from information_schema.columns
            where table_schema = 'public' and table_name = 'v_entrega_a_caminho'),
          array['rota_id','ponto_id','catador_nome','qtd_sacos','eta','chegou'], 'view sem endereco/identificacao de geradores');
reset role; update rota_paradas set status = 'no_local' where rota_id = public._u('a4000000', 2) and tipo = 'descarte';
select public._as(public._u('a1000000', 7));
select is((select chegou from v_entrega_a_caminho), true, 'chegou quando o descarte esta no_local');
reset role; select public._as(public._u('a1000000', 8));   -- operador de outro ponto
select is((select count(*)::int from v_entrega_a_caminho), 0, 'operador de outro ponto nao ve a entrega');
reset role; select public._as(public._u('a1000000', 3));   -- gerador
select is((select count(*)::int from v_entrega_a_caminho), 0, 'gerador nao ve entregas a caminho');
reset role; select public._as(public._u('a1000000', 6));   -- catador da rota
select is((select count(*)::int from v_entrega_a_caminho), 0, 'catador nao usa a visao do ponto');
reset role; update rotas set status = 'planejada' where id = public._u('a4000000', 2);
select public._as(public._u('a1000000', 7));
select is((select count(*)::int from v_entrega_a_caminho), 0, 'rota nao iniciada nao aparece');
reset role;

-- ---------- Realtime e grants pedidos (P-019..P-023) ----------
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ofertas'), 'ofertas no Realtime');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rotas'), 'rotas no Realtime');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rota_paradas'), 'rota_paradas no Realtime');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'solicitacoes'), 'solicitacoes no Realtime');
select ok(has_table_privilege('authenticated', 'public.v_oferta_resumo', 'select'), 'authenticated le v_oferta_resumo');
select ok(has_function_privilege('authenticated', 'public.iniciar_rota(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.avancar_parada(uuid,text,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.trocar_ponto_destino(uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.atualizar_localizacao(float8,float8,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.registrar_entrega(uuid,jsonb)', 'execute'), 'execute das RPCs do ciclo para authenticated');

-- ---------- resetar_demo ----------
create temp table t_t0 as select clock_timestamp() as t;
select public._as(public._u('a1000000', 1));
select lives_ok($$select public.resetar_demo()$$, 'admin reseta a demo');
reset role;
select ok(clock_timestamp() - (select t from t_t0) < interval '10 seconds', 'resetar_demo em menos de 10 s');
select is((select count(*)::int from solicitacoes), 0, 'reset apaga solicitacoes');
select is((select count(*)::int from rotas), 0, 'reset apaga rotas');
select is((select count(*)::int from demo_atores where origem = 'demo'), 0, 'reset remove os catadores criados pela demo');
select is((select count(*)::int from auth.users where email like '%@demo.kaptalixo.local'), 0, 'reset remove as contas demo');
select ok((select count(*) from catadores where perfil_id = public._u('a1000000', 5)) = 1, 'reset preserva atores do seed');

select * from finish();
rollback;
