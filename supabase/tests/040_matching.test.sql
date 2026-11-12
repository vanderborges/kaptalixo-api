-- T1.4: matching e ofertas (UC03/UC04/UC05; RN01-RN04, RN08, RN10).
-- Autonomo: fixtures proprias longe do seed (lat 50..52) e criadas dentro da transacao.
begin;
select plan(91);

-- ---------- fixtures ----------
create function public._ger(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000a0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._cat(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000c0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._claim(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform public._claim(p); set local role authenticated; end $$;
-- catador a `dist` metros ao norte de (lat, 10)
create function public._mkcat(n int, lat float8, dist float8, cap int default 10,
                              sit disponibilidade default 'disponivel', st status_cadastro default 'aprovado') returns void
language plpgsql as $$
begin
  insert into auth.users (id) values (public._cat(n));
  insert into perfis (id, papel, nome) values (public._cat(n), 'catador', 'Cat ' || n);
  insert into catadores (perfil_id, status_cadastro, capacidade_sacos, situacao, localizacao_atual)
  values (public._cat(n), st, cap, sit,
          st_project(st_setsrid(st_makepoint(10, lat), 4326)::geography, dist, 0));
end $$;
create function public._pendente(sol uuid) returns uuid language sql security definer set search_path = public as
$$ select id from ofertas where solicitacao_id = sol and status = 'pendente' $$;
create function public._recusa_pendente(sol uuid) returns void language plpgsql as $$
declare o ofertas%rowtype;
begin
  select * into o from ofertas where solicitacao_id = sol and status = 'pendente';
  perform public._claim(o.catador_id);
  perform public.recusar_oferta(o.id);
end $$;
create function public._expira_pendente(sol uuid) returns int language plpgsql as $$
begin
  update ofertas set expira_em = now() - interval '1 second' where solicitacao_id = sol and status = 'pendente';
  perform set_config('request.jwt.claims', '', true);
  return public.expirar_ofertas();
end $$;

grant execute on function public._ger(int), public._cat(int), public._claim(uuid), public._as(uuid), public._pendente(uuid) to authenticated;

insert into auth.users (id) select public._ger(g) from generate_series(1, 3) g;
insert into perfis (id, papel, nome)
select public._ger(g), 'gerador', 'Ger ' || g from generate_series(1, 3) g;
insert into geradores (perfil_id) select public._ger(g) from generate_series(1, 3) g;
insert into materiais (id, codigo, nome, categoria) values (1, 'papel', 'Papel', 'papel') on conflict do nothing;

-- cenario A (lat 50): ordem, filtros e expansao de raio
select public._mkcat(1, 50, 1000);
select public._mkcat(2, 50, 2000);
select public._mkcat(3, 50, 4000);
select public._mkcat(4, 50, 500, 10, 'offline');
select public._mkcat(5, 50, 600, 10, 'disponivel', 'pendente');
select public._mkcat(6, 50, 700, 1);
select public._mkcat(7, 50, 6000);
-- cenario B (lat 51): 6 elegiveis, so 5 ofertas
select public._mkcat(g, 51, 500.0 * (g - 10)) from generate_series(11, 16) g;
-- cenario C/D (lat 52)
select public._mkcat(21, 52, 1000);
select public._mkcat(22, 52, 2000);

-- ---------- permissoes de funcao ----------
select ok(has_function_privilege('authenticated', 'public.criar_solicitacao(float8,float8,text,int,tamanho_saco,smallint[],text,text,timestamptz)', 'execute'), 'authenticated executa criar_solicitacao');
select ok(has_function_privilege('authenticated', 'public.aceitar_oferta(uuid)', 'execute'), 'authenticated executa aceitar_oferta');
select ok(has_function_privilege('authenticated', 'public.recusar_oferta(uuid)', 'execute'), 'authenticated executa recusar_oferta');
select ok(has_function_privilege('authenticated', 'public.expirar_ofertas()', 'execute'), 'authenticated executa expirar_ofertas');
select ok(not has_function_privilege('anon', 'public.criar_solicitacao(float8,float8,text,int,tamanho_saco,smallint[],text,text,timestamptz)', 'execute'), 'anon nao executa criar_solicitacao');
select ok(not has_function_privilege('anon', 'public.aceitar_oferta(uuid)', 'execute'), 'anon nao executa aceitar_oferta');
select ok(not has_function_privilege('anon', 'public.expirar_ofertas()', 'execute'), 'anon nao executa expirar_ofertas');
select ok(not has_function_privilege('authenticated', 'public.gerar_proxima_oferta(uuid)', 'execute'), 'gerar_proxima_oferta e interna');
select ok(not has_function_privilege('authenticated', 'public.buscar_catadores_proximos(float8,float8,int,int,uuid[],int)', 'execute'), 'buscar_catadores_proximos e interna (nao vaza posicoes)');
select ok(exists (select 1 from cron.job where jobname = 'kaptalixo-expirar-ofertas' and command like '%expirar_ofertas%'), 'job pg_cron de expiracao agendado');

-- ---------- buscar_catadores_proximos (interna, como postgres) ----------
select is((select array_agg(catador_id order by distancia_m) from public.buscar_catadores_proximos(50, 10, 8000, 3, '{}', 10)),
          array[public._cat(1), public._cat(2), public._cat(3), public._cat(7)],
          'busca: ordem por distancia; offline, pendente e sem capacidade ignorados');
select is((select count(*)::int from public.buscar_catadores_proximos(50, 10, 3000, 3, '{}', 10)), 2, 'busca: raio de 3 km acha 2');
select is((select array_agg(catador_id) from public.buscar_catadores_proximos(50, 10, 8000, 3, array[public._cat(1)], 1)),
          array[public._cat(2)], 'busca: p_excluir e p_limite respeitados');
select ok((select abs(distancia_m - 1000) < 1 from public.buscar_catadores_proximos(50, 10, 3000, 3, '{}', 1)), 'busca: distancia_m exata');
select ok(not (select bool_or(em_rota) from public.buscar_catadores_proximos(50, 10, 8000, 3, '{}', 10)), 'busca: em_rota false (RN05 fica para o UC10)');

-- ---------- criar_solicitacao: validacoes e permissao ----------
reset role; select public._as(public._cat(1));
select throws_ok($$select public.criar_solicitacao(50, 10, 'x', 3)$$, 'P0001', 'sem_permissao', 'catador nao cria solicitacao');
reset role; select public._claim(null);
select throws_ok($$select public.criar_solicitacao(50, 10, 'x', 3)$$, 'P0001', 'sem_permissao', 'sem login nao cria solicitacao');
reset role; select public._as(public._ger(1));
select throws_ok($$select public.criar_solicitacao(50, 10, 'x', 0)$$, 'P0001', 'parametro_invalido', 'RN01: 0 sacos invalido');
select throws_ok($$select public.criar_solicitacao(50, 10, 'x', 21)$$, 'P0001', 'parametro_invalido', 'RN01: 21 sacos invalido');
select throws_ok($$select public.criar_solicitacao(95, 10, 'x', 3)$$, 'P0001', 'parametro_invalido', 'latitude invalida');
select throws_ok($$select public.criar_solicitacao(50, 10, 'x', 3, 'M', array[99]::smallint[])$$, 'P0001', 'parametro_invalido', 'material inexistente');
select throws_ok($$select public.criar_solicitacao(50, 10, 'x', 3, 'M', '{}', null, null, now() - interval '1 day')$$, 'P0001', 'parametro_invalido', 'agendamento no passado');
select is((select count(*)::int from solicitacoes), 0, 'validacoes nao criam nada');

-- ---------- cenario A: UC04 (ordem, recusa, expiracao, expansao 3 -> 5 -> 8 km, sem_catador) ----------
select set_config('t.sa', public.criar_solicitacao(50, 10, 'Rua A, 1', 3, 'G', array[1, 1]::smallint[], 'portao azul')::text, true);
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sa')::uuid), 'buscando', 'A: solicitacao nasce buscando');
select ok((select pin_coleta ~ '^[0-9]{4}$' from solicitacoes where id = current_setting('t.sa')::uuid), 'A: RN08 PIN de 4 digitos gerado');
select is((select peso_estimado_kg from solicitacoes where id = current_setting('t.sa')::uuid), 30.00::numeric, 'A: RN07 peso estimado 3 x 10 kg');
select is((select count(*)::int from solicitacao_materiais where solicitacao_id = current_setting('t.sa')::uuid), 1, 'A: materiais sem duplicar');
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sa')::uuid)), public._cat(1), 'A: primeira oferta vai ao mais proximo (1 km)');
select ok((select distancia_m between 999 and 1001 and eta_s between 195 and 205 and ordem = 1 and expira_em between now() + interval '44 seconds' and now() + interval '46 seconds'
             from ofertas where id = public._pendente(current_setting('t.sa')::uuid)), 'A: oferta grava distancia/eta exatos, ordem 1, validade 45 s');
select is((select tentativas_oferta from solicitacoes where id = current_setting('t.sa')::uuid), 1, 'A: tentativas_oferta = 1');
select is((select count(*)::int from eventos_solicitacao where solicitacao_id = current_setting('t.sa')::uuid and para_status = 'buscando'), 1, 'A: evento de auditoria registrado');
select is((select count(*)::int from notificacoes where perfil_id = public._cat(1) and tipo = 'nova_oferta'), 1, 'A: catador notificado da oferta');

-- recusa de usuario errado e de gerador
select public._as(public._cat(2));
select throws_ok(format($$select public.recusar_oferta(%L)$$, public._pendente(current_setting('t.sa')::uuid)), 'P0001', 'oferta_inexistente', 'A: outro catador nao recusa oferta alheia');
select throws_ok(format($$select public.aceitar_oferta(%L)$$, public._pendente(current_setting('t.sa')::uuid)), 'P0001', 'oferta_inexistente', 'A: outro catador nao aceita oferta alheia');
reset role; select public._as(public._ger(1));
select throws_ok(format($$select public.recusar_oferta(%L)$$, public._pendente(current_setting('t.sa')::uuid)), 'P0001', 'sem_permissao', 'A: gerador nao recusa oferta');
reset role;
select is((select status::text from ofertas where id = public._pendente(current_setting('t.sa')::uuid)), 'pendente', 'A: tentativas indevidas nao alteram a oferta');

-- recusa legitima passa ao proximo
select public._as(public._cat(1));
select lives_ok(format($$select public.recusar_oferta(%L)$$, public._pendente(current_setting('t.sa')::uuid)), 'A: catador 1 recusa');
reset role;
select is((select status::text from ofertas where solicitacao_id = current_setting('t.sa')::uuid and catador_id = public._cat(1)), 'recusada', 'A: oferta 1 recusada');
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sa')::uuid)), public._cat(2), 'A: recusa passa ao proximo (2 km)');
select public._as(public._cat(1));
select throws_ok(format($$select public.recusar_oferta(%L)$$, (select id from ofertas where catador_id = public._cat(1) and solicitacao_id = current_setting('t.sa')::uuid)), 'P0001', 'oferta_indisponivel', 'A: recusar duas vezes falha');
reset role;

-- expiracao pelo job
select is(public._expira_pendente(current_setting('t.sa')::uuid), 1, 'A: expirar_ofertas expira 1');
select is((select status::text from ofertas where solicitacao_id = current_setting('t.sa')::uuid and catador_id = public._cat(2)), 'expirada', 'A: oferta 2 expirada');
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sa')::uuid)), public._cat(3), 'A: expiracao passa ao proximo; raio expande para 5 km (4 km)');
select is(public._expira_pendente(current_setting('t.sa')::uuid), 1, 'A: expira a oferta do catador 3');
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sa')::uuid)), public._cat(7), 'A: raio expande para 8 km (6 km)');
select is(public.expirar_ofertas(), 0, 'A: expirar_ofertas e idempotente (nada vencido)');
select public._recusa_pendente(current_setting('t.sa')::uuid);
select is((select status::text from solicitacoes where id = current_setting('t.sa')::uuid), 'sem_catador', 'A: sem candidatos -> sem_catador');
select is((select count(*)::int from ofertas where solicitacao_id = current_setting('t.sa')::uuid and catador_id in (public._cat(4), public._cat(5), public._cat(6))), 0, 'A: offline, pendente e sem capacidade nunca receberam oferta');
select is((select count(distinct catador_id)::int from ofertas where solicitacao_id = current_setting('t.sa')::uuid), 4, 'A: nunca oferta duas vezes ao mesmo catador (4 ofertas, 4 catadores)');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(1) and tipo = 'sem_catador'), 1, 'A: gerador notificado do sem_catador');
select is(public.gerar_proxima_oferta(current_setting('t.sa')::uuid), null, 'A: gerar_proxima_oferta em solicitacao encerrada nao faz nada');

-- ---------- cenario B: 5 ofertas sem aceite -> sem_catador (RN03) ----------
select public._as(public._ger(2));
select set_config('t.sb', public.criar_solicitacao(51, 10, 'Rua B, 2', 2)::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sb')::uuid)), public._cat(11), 'B: primeira oferta ao mais proximo');
select public._recusa_pendente(current_setting('t.sb')::uuid);
select public._expira_pendente(current_setting('t.sb')::uuid);
select public._recusa_pendente(current_setting('t.sb')::uuid);
select public._expira_pendente(current_setting('t.sb')::uuid);
select is((select status::text from solicitacoes where id = current_setting('t.sb')::uuid), 'buscando', 'B: apos 4 ofertas segue buscando');
select is((select tentativas_oferta from solicitacoes where id = current_setting('t.sb')::uuid), 5, 'B: 5a oferta enviada (tentativas = 5)');
select public._recusa_pendente(current_setting('t.sb')::uuid);
select is((select status::text from solicitacoes where id = current_setting('t.sb')::uuid), 'sem_catador', 'B: 5 ofertas sem aceite -> sem_catador');
select is((select count(*)::int from ofertas where solicitacao_id = current_setting('t.sb')::uuid), 5, 'B: no maximo 5 ofertas');
select is((select count(*)::int from ofertas where solicitacao_id = current_setting('t.sb')::uuid and catador_id = public._cat(16)), 0, 'B: 6o catador elegivel nao recebe oferta');
select is((select array_agg(ordem order by ordem) from ofertas where solicitacao_id = current_setting('t.sb')::uuid), array[1, 2, 3, 4, 5], 'B: ordem das ofertas 1..5');

-- ---------- cenario C: UC05 aceite ----------
select public._as(public._ger(3));
select set_config('t.sc', public.criar_solicitacao(52, 10, 'Rua C, 3', 4, 'P', '{}', 'casa verde', null)::text, true);
reset role;
select set_config('t.oc', public._pendente(current_setting('t.sc')::uuid)::text, true);
select is((select catador_id from ofertas where id = current_setting('t.oc')::uuid), public._cat(21), 'C: oferta ao catador 21');

select public._as(public._cat(21));
select is((select count(*)::int from solicitacoes), 0, 'C: catador com oferta pendente nao le a solicitacao (sem endereco exato antes do aceite)');
select is((select count(*)::int from v_oferta_resumo), 1, 'C: catador ve a oferta pela view resumida');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'C: catador nao le pin_coleta');
select throws_ok($$select * from public.buscar_catadores_proximos(52, 10, 8000, 1, '{}', 5)$$, '42501', null, 'C: catador nao chama a busca interna');
select throws_ok(format($$select public.gerar_proxima_oferta(%L)$$, current_setting('t.sc')), '42501', null, 'C: catador nao chama gerar_proxima_oferta');
reset role; select public._as(public._ger(3));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.oc')), 'P0001', 'sem_permissao', 'C: gerador nao aceita oferta');
select throws_ok($$select public.criar_solicitacao(52, 10, 'Rua C, 3', 2)$$, 'P0001', 'solicitacao_ativa_existente', 'C: 2a solicitacao ativa do gerador falha');
reset role; select public._as(public._cat(22));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.oc')), 'P0001', 'oferta_inexistente', 'C: catador errado nao aceita');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sc')::uuid), 'buscando', 'C: tentativa errada nao altera a solicitacao');

select public._as(public._cat(21));
select set_config('t.rc', public.aceitar_oferta(current_setting('t.oc')::uuid)::text, true);
select is((select count(*)::int from solicitacoes where id = current_setting('t.sc')::uuid), 1, 'C: apos aceite o catador le a solicitacao');
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.oc')), 'P0001', 'oferta_indisponivel', 'C: segundo aceite da mesma oferta falha (primeiro vence)');
select throws_ok(format($$select public.recusar_oferta(%L)$$, current_setting('t.oc')), 'P0001', 'oferta_indisponivel', 'C: nao recusa oferta ja aceita');
select is((select count(*)::int from v_solicitacao_catador where id = current_setting('t.sc')::uuid), 1, 'C: view do catador mostra a coleta aceita');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'C: catador segue sem ler pin_coleta apos aceite');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sc')::uuid), 'aceita', 'C: solicitacao aceita');
select is((select catador_id from solicitacoes where id = current_setting('t.sc')::uuid), public._cat(21), 'C: catador atribuido');
select is((select status::text from ofertas where id = current_setting('t.oc')::uuid), 'aceita', 'C: oferta aceita');
select is((select situacao::text from catadores where perfil_id = public._cat(21)), 'em_rota', 'C: catador em_rota');
select is((select status::text from rotas where id = current_setting('t.rc')::uuid), 'planejada', 'C: rota planejada criada');
select is((select count(*)::int from rota_paradas where rota_id = current_setting('t.rc')::uuid and tipo = 'coleta' and solicitacao_id = current_setting('t.sc')::uuid and ordem = 1), 1, 'C: parada de coleta criada');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(3) and tipo = 'oferta_aceita'), 1, 'C: gerador notificado do aceite');
select public._as(public._ger(3));
select ok((select pin_coleta ~ '^[0-9]{4}$' from v_solicitacao_gerador where id = current_setting('t.sc')::uuid), 'C: gerador le o proprio PIN');
reset role;

-- ---------- cenario D: aceite invalido (offline, capacidade, expirada) ----------
select public._as(public._ger(1));
select set_config('t.sd', public.criar_solicitacao(52, 10, 'Rua D, 4', 5)::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sd')::uuid)), public._cat(22), 'D: retry apos sem_catador; oferta ao catador 22 (21 esta em rota)');
select set_config('t.od', public._pendente(current_setting('t.sd')::uuid)::text, true);

update catadores set situacao = 'offline' where perfil_id = public._cat(22);
select public._as(public._cat(22));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.od')), 'P0001', 'catador_indisponivel', 'D: catador offline nao aceita');
reset role;
update catadores set situacao = 'disponivel', capacidade_sacos = 2 where perfil_id = public._cat(22);
select public._as(public._cat(22));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.od')), 'P0001', 'sem_capacidade', 'D: RN04 sem capacidade nao aceita');
reset role;
update catadores set capacidade_sacos = 10 where perfil_id = public._cat(22);
update ofertas set expira_em = now() - interval '1 second' where id = current_setting('t.od')::uuid;
select public._as(public._cat(22));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.od')), 'P0001', 'oferta_expirada', 'D: aceitar apos expirar retorna erro');
reset role;
select is((select status::text from ofertas where id = current_setting('t.od')::uuid), 'pendente', 'D: aceite expirado nao altera a oferta');
select is((select status::text from solicitacoes where id = current_setting('t.sd')::uuid), 'buscando', 'D: nem a solicitacao');
select is((select situacao::text from catadores where perfil_id = public._cat(22)), 'disponivel', 'D: nem o catador');
select is((select count(*)::int from rotas where catador_id = public._cat(22)), 0, 'D: nenhuma rota criada');
select is(public._expira_pendente(current_setting('t.sd')::uuid), 1, 'D: job expira a oferta vencida');
select is((select status::text from solicitacoes where id = current_setting('t.sd')::uuid), 'sem_catador', 'D: sem outro candidato -> sem_catador');

select * from finish();
rollback;
