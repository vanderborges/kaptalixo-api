begin;
select plan(53);

-- ---------- existencia das tabelas ----------
select has_table('public', t, 'tabela ' || t || ' existe')
from unnest(array[
  'perfis','enderecos','geradores','catadores','materiais','pontos_coleta','ponto_precos',
  'solicitacoes','solicitacao_materiais','eventos_solicitacao','ofertas','rotas','rota_paradas',
  'entregas','entrega_itens','avaliacoes','notificacoes','localizacoes_catador','parametros'
]) as t; -- 19

-- ---------- enums ----------
select has_type('public', 'status_solicitacao', 'enum status_solicitacao existe');
select enum_has_labels('public', 'status_solicitacao',
  array['buscando','aceita','a_caminho','no_local','coletada','entregue','cancelada','sem_catador'],
  'status_solicitacao com todos os rotulos');

-- ---------- indices unicos parciais ----------
select ok(
  (select indexdef from pg_indexes where indexname = 'solic_uma_ativa_por_gerador') ilike 'create unique index%where%',
  'solic_uma_ativa_por_gerador e unico parcial');
select ok(
  (select indexdef from pg_indexes where indexname = 'ofertas_uma_pendente_por_solic') ilike 'create unique index%where%',
  'ofertas_uma_pendente_por_solic e unico parcial');
select ok(
  (select indexdef from pg_indexes where indexname = 'rotas_uma_aberta_por_catador') ilike 'create unique index%where%',
  'rotas_uma_aberta_por_catador e unico parcial');

-- ---------- RLS ligado em todas as tabelas ----------
select is(
  (select count(*)::int from pg_tables t join pg_class c on c.relname = t.tablename
     where t.schemaname = 'public' and c.relnamespace = 'public'::regnamespace and not c.relrowsecurity),
  0, 'nenhuma tabela de public sem RLS');

-- ---------- parametros ----------
select is((select count(*)::int from parametros), 12, '12 parametros carregados');
select is((select valor from parametros where chave = 'raios_busca_m'), '[3000,5000,8000]'::jsonb, 'raios_busca_m');
select is((select valor from parametros where chave = 'peso_saco_kg'), '{"P":2,"M":5,"G":10}'::jsonb, 'peso_saco_kg');
select is((select valor from parametros where chave = 'modo_demo'), 'true'::jsonb, 'modo_demo = true');

-- ---------- Realtime ----------
select is(
  (select count(*)::int from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename in ('solicitacoes','ofertas','rotas','rota_paradas','catadores','entregas','notificacoes')),
  7, 'as 7 tabelas estao na publicacao supabase_realtime');

-- ---------- grants: anon/authenticated sem acesso ----------
select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon'),
  0, 'anon sem grants em tabelas de public (authenticated: ver 020_rls)');

create table public._tmp_grants (id int);
create function public._tmp_fn() returns int language sql as 'select 1';
select ok(not has_table_privilege('anon', 'public._tmp_grants', 'select'), 'default privileges: anon sem select em tabela nova');
select ok(not has_table_privilege('authenticated', 'public._tmp_grants', 'select'), 'default privileges: authenticated sem select em tabela nova');
select ok(not has_function_privilege('anon', 'public._tmp_fn()', 'execute'), 'default privileges: anon sem execute em funcao nova');
select ok(not has_function_privilege('authenticated', 'public._tmp_fn()', 'execute'), 'default privileges: authenticated sem execute em funcao nova');
select ok(not has_function_privilege('anon', 'public.tg_solicitacao_evento()', 'execute'), 'funcao de trigger nao executavel por anon');
select ok(not has_function_privilege('authenticated', 'public.tg_solicitacao_evento()', 'execute'), 'funcao de trigger nao executavel por authenticated');

-- ---------- dados de apoio ----------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000a3');
insert into perfis (id, papel, nome) values
  ('00000000-0000-0000-0000-0000000000a1', 'gerador', 'Gerador Teste'),
  ('00000000-0000-0000-0000-0000000000a2', 'catador', 'Catador Teste'),
  ('00000000-0000-0000-0000-0000000000a3', 'ponto',   'Ponto Teste');
insert into geradores (perfil_id) values ('00000000-0000-0000-0000-0000000000a1');
insert into catadores (perfil_id) values ('00000000-0000-0000-0000-0000000000a2');
insert into materiais (id, codigo, nome, categoria) values (1, 'papel', 'Papel', 'papel') on conflict do nothing;
insert into pontos_coleta (id, nome, logradouro, cidade, uf, localizacao) values
  ('00000000-0000-0000-0000-0000000000b1', 'Ponto', 'Rua A', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.63 -23.55)'::geography);

-- ---------- checks de solicitacoes ----------
select throws_ok($$
  insert into solicitacoes (gerador_id, localizacao, qtd_sacos, pin_coleta)
  values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(-46.63 -23.55)'::geography, 0, '1234')
$$, '23514', null, 'qtd_sacos = 0 viola check');
select throws_ok($$
  insert into solicitacoes (gerador_id, localizacao, qtd_sacos, pin_coleta)
  values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(-46.63 -23.55)'::geography, 21, '1234')
$$, '23514', null, 'qtd_sacos = 21 viola check');

insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, pin_coleta)
values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1',
        'SRID=4326;POINT(-46.63 -23.55)'::geography, 2, '1234');

-- indice unico parcial: segunda ativa do mesmo gerador
select throws_ok($$
  insert into solicitacoes (gerador_id, localizacao, qtd_sacos, pin_coleta)
  values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(-46.63 -23.55)'::geography, 1, '5678')
$$, '23505', null, 'segunda solicitacao ativa do mesmo gerador e rejeitada');

-- ---------- triggers ----------
select is((select count(*)::int from eventos_solicitacao where solicitacao_id = '00000000-0000-0000-0000-0000000000c1'
            and de_status is null and para_status = 'buscando'), 1, 'insert gera evento inicial (de_status nulo)');

update solicitacoes set atualizado_em = now() - interval '1 day' where id = '00000000-0000-0000-0000-0000000000c1';
update solicitacoes set status = 'cancelada', motivo_cancelamento = 'teste'
 where id = '00000000-0000-0000-0000-0000000000c1';
select is((select count(*)::int from eventos_solicitacao where solicitacao_id = '00000000-0000-0000-0000-0000000000c1'
            and de_status = 'buscando' and para_status = 'cancelada'), 1, 'mudanca de status gera evento');
select ok((select atualizado_em from solicitacoes where id = '00000000-0000-0000-0000-0000000000c1') > now() - interval '1 minute',
  'atualizado_em e renovado no update');

update solicitacoes set observacao = 'x' where id = '00000000-0000-0000-0000-0000000000c1';
select is((select count(*)::int from eventos_solicitacao where solicitacao_id = '00000000-0000-0000-0000-0000000000c1'), 2,
  'update sem mudar status nao gera evento');

-- apos cancelar, o gerador pode criar nova ativa
select lives_ok($$
  insert into solicitacoes (gerador_id, localizacao, qtd_sacos, pin_coleta)
  values ('00000000-0000-0000-0000-0000000000a1', 'SRID=4326;POINT(-46.63 -23.55)'::geography, 1, '5678')
$$, 'solicitacao cancelada libera nova ativa');

-- ---------- ofertas ----------
insert into ofertas (id, solicitacao_id, catador_id, ordem, expira_em)
values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1',
        '00000000-0000-0000-0000-0000000000a2', 1, now() + interval '45 seconds');
select throws_ok($$
  insert into ofertas (solicitacao_id, catador_id, ordem, expira_em)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a2', 2, now())
$$, '23505', null, 'mesmo catador nao recebe 2x a mesma solicitacao');

-- ---------- rotas e paradas ----------
insert into rotas (id, catador_id) values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a2');
select throws_ok($$
  insert into rotas (catador_id) values ('00000000-0000-0000-0000-0000000000a2')
$$, '23505', null, 'segunda rota aberta do catador e rejeitada');
select lives_ok($$
  insert into rotas (catador_id, status) values ('00000000-0000-0000-0000-0000000000a2', 'concluida')
$$, 'rota concluida nao conta como aberta');

select throws_ok($$
  insert into rota_paradas (rota_id, ordem, tipo, localizacao)
  values ('00000000-0000-0000-0000-0000000000e1', 1, 'coleta', 'SRID=4326;POINT(-46.63 -23.55)'::geography)
$$, '23514', null, 'parada de coleta sem solicitacao viola check');
select throws_ok($$
  insert into rota_paradas (rota_id, ordem, tipo, solicitacao_id, ponto_id, localizacao)
  values ('00000000-0000-0000-0000-0000000000e1', 1, 'descarte', '00000000-0000-0000-0000-0000000000c1',
          '00000000-0000-0000-0000-0000000000b1', 'SRID=4326;POINT(-46.63 -23.55)'::geography)
$$, '23514', null, 'parada de descarte com solicitacao viola check');
select lives_ok($$
  insert into rota_paradas (rota_id, ordem, tipo, ponto_id, localizacao)
  values ('00000000-0000-0000-0000-0000000000e1', 1, 'descarte', '00000000-0000-0000-0000-0000000000b1',
          'SRID=4326;POINT(-46.63 -23.55)'::geography)
$$, 'parada de descarte coerente e aceita');

-- ---------- avaliacoes ----------
select throws_ok($$
  insert into avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 6)
$$, '23514', null, 'nota 6 viola check');
select throws_ok($$
  insert into avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', 5)
$$, '23514', null, 'auto-avaliacao viola check');

select * from finish();
rollback;
