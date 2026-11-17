-- T1.7: confirmar_entrega (entrega simplificada no ponto). Fixtures proprias (lat 50..52), dentro da transacao.
begin;
select plan(22);

create function public._u(p text, n int) returns uuid language sql immutable as
$$ select (p || '-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); set local role authenticated; end $$;
grant execute on function public._u(text, int), public._as(uuid) to authenticated;

insert into auth.users (id) select public._u('a1000000', g) from generate_series(1, 2) g;
insert into perfis (id, papel, nome) select public._u('a1000000', g), 'gerador', 'Ger ' || g from generate_series(1, 2) g;
insert into geradores (perfil_id) select public._u('a1000000', g) from generate_series(1, 2) g;
insert into auth.users (id) select public._u('c1000000', g) from generate_series(1, 2) g;
insert into perfis (id, papel, nome) select public._u('c1000000', g), 'catador', 'Cat ' || g from generate_series(1, 2) g;
insert into catadores (perfil_id, status_cadastro, capacidade_sacos, situacao, localizacao_atual)
select public._u('c1000000', g), 'aprovado', 10, 'em_rota', st_setsrid(st_makepoint(10, 50), 4326)::geography from generate_series(1, 2) g;
insert into auth.users (id) select public._u('b1000000', g) from generate_series(1, 2) g;
insert into perfis (id, papel, nome) select public._u('b1000000', g), 'ponto', 'Pon ' || g from generate_series(1, 2) g;
insert into pontos_coleta (id, perfil_id, nome, logradouro, cidade, uf, localizacao, ativo)
select public._u('f1000000', g), public._u('b1000000', g), 'P' || g, 'Rua ' || g, 'X', 'SP',
       st_setsrid(st_makepoint(10, 50 + 0.01 * g), 4326)::geography, true from generate_series(1, 2) g;

-- rota 1 (catador 1, destino ponto 1): coleta concluida (solicitacao coletada), descarte no_local
-- rota 2 (catador 2, destino ponto 1): coleta ainda pendente
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id) values
  (public._u('51000000', 1), public._u('a1000000', 1), st_setsrid(st_makepoint(10, 50), 4326)::geography, 1, 'M', 5, 'coletada', '1111', public._u('c1000000', 1)),
  (public._u('51000000', 2), public._u('a1000000', 2), st_setsrid(st_makepoint(10, 50), 4326)::geography, 1, 'M', 5, 'aceita',   '2222', public._u('c1000000', 2));
insert into rotas (id, catador_id, status, ponto_destino_id, iniciada_em) values
  (public._u('d1000000', 1), public._u('c1000000', 1), 'em_andamento', public._u('f1000000', 1), now()),
  (public._u('d1000000', 2), public._u('c1000000', 2), 'em_andamento', public._u('f1000000', 1), now());
insert into rota_paradas (rota_id, ordem, tipo, solicitacao_id, localizacao, status) values
  (public._u('d1000000', 1), 1, 'coleta', public._u('51000000', 1), st_setsrid(st_makepoint(10, 50), 4326)::geography, 'concluida'),
  (public._u('d1000000', 2), 1, 'coleta', public._u('51000000', 2), st_setsrid(st_makepoint(10, 50), 4326)::geography, 'pendente');
insert into rota_paradas (rota_id, ordem, tipo, ponto_id, localizacao, status)
select r, 2, 'descarte', public._u('f1000000', 1), st_setsrid(st_makepoint(10, 50.01), 4326)::geography, 'no_local'
  from (values (public._u('d1000000', 1)), (public._u('d1000000', 2))) v(r);

select ok(has_function_privilege('authenticated', 'public.confirmar_entrega(uuid)', 'execute'), 'authenticated executa confirmar_entrega');
select ok(not has_function_privilege('anon', 'public.confirmar_entrega(uuid)', 'execute'), 'anon nao executa confirmar_entrega');

-- permissao
select public._as(public._u('a1000000', 1));
select throws_ok(format($$select public.confirmar_entrega(%L)$$, public._u('d1000000', 1)), 'P0001', 'sem_permissao', 'gerador nao confirma');
reset role; select public._as(public._u('c1000000', 1));
select throws_ok(format($$select public.confirmar_entrega(%L)$$, public._u('d1000000', 1)), 'P0001', 'sem_permissao', 'catador nao confirma a propria entrega');
reset role; select public._as(public._u('b1000000', 2));
select throws_ok(format($$select public.confirmar_entrega(%L)$$, public._u('d1000000', 1)), 'P0001', 'rota_inexistente', 'ponto de outro destino nao confirma');
select throws_ok(format($$select public.confirmar_entrega(%L)$$, gen_random_uuid()), 'P0001', 'rota_inexistente', 'rota inexistente');
reset role;
select is((select count(*)::int from entregas), 0, 'negativas nao criam entrega');

-- rota com coleta pendente
select public._as(public._u('b1000000', 1));
select throws_ok(format($$select public.confirmar_entrega(%L)$$, public._u('d1000000', 2)), 'P0001', 'coletas_pendentes', 'rota com coleta pendente negada');
reset role;
select is((select status::text from rotas where id = public._u('d1000000', 2)), 'em_andamento', 'rota pendente segue em andamento');

-- rota sem nenhuma coleta concluida (coleta pulada)
update rota_paradas set status = 'pulada' where rota_id = public._u('d1000000', 2) and tipo = 'coleta';
select public._as(public._u('b1000000', 1));
select throws_ok(format($$select public.confirmar_entrega(%L)$$, public._u('d1000000', 2)), 'P0001', 'sem_coletas', 'rota sem coletas concluidas negada');

-- caminho feliz
select set_config('t.e', public.confirmar_entrega(public._u('d1000000', 1))::text, true);
select is((select count(*)::int from entregas where rota_id = public._u('d1000000', 1)), 1, 'operador le a entrega criada');
reset role;
select is((select count(*)::int from entregas where id = current_setting('t.e')::uuid and ponto_id = public._u('f1000000', 1)
           and catador_id = public._u('c1000000', 1) and registrada_por = public._u('b1000000', 1)
           and peso_total_kg = 0 and valor_total = 0), 1, 'entrega sem peso/valor, ligada ao ponto e catador');
select is((select count(*)::int from entrega_itens where entrega_id = current_setting('t.e')::uuid), 0, 'sem itens');
select is((select status::text from solicitacoes where id = public._u('51000000', 1)), 'entregue', 'solicitacao entregue');
select is((select status::text from rotas where id = public._u('d1000000', 1)), 'concluida', 'rota concluida');
select is((select status::text from rota_paradas where rota_id = public._u('d1000000', 1) and tipo = 'descarte'), 'concluida', 'parada de descarte concluida');
select is((select situacao::text from catadores where perfil_id = public._u('c1000000', 1)), 'disponivel', 'catador disponivel');
select is((select count(*)::int from notificacoes where perfil_id = public._u('a1000000', 1) and tipo = 'coleta_entregue' and titulo = 'Entrega confirmada'), 1, 'gerador notificado');
select is((select count(*)::int from notificacoes where perfil_id = public._u('c1000000', 1) and tipo = 'entrega_registrada' and titulo = 'Entrega confirmada'), 1, 'catador notificado');
select is((select situacao::text from catadores where perfil_id = public._u('c1000000', 2)), 'em_rota', 'outra rota nao e afetada');

-- repetida
select public._as(public._u('b1000000', 1));
select throws_ok(format($$select public.confirmar_entrega(%L)$$, public._u('d1000000', 1)), 'P0001', 'rota_invalida', 'chamada repetida negada');
reset role;
select is((select count(*)::int from entregas where rota_id = public._u('d1000000', 1)), 1, 'continua uma unica entrega');

select * from finish();
rollback;
