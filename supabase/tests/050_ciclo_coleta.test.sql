-- T1.5: ciclo da coleta (UC08, UC11-UC14; RN08-RN12), P-005 (view de rota), P-009 (limites) e retencao.
-- Autonomo: fixtures proprias longe do seed (lat 50..62) criadas dentro da transacao.
begin;
select plan(244);

-- ---------- fixtures ----------
create function public._ger(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000a0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._cat(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000c0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._pon(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000b0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._pto(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000f0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._adm() returns uuid language sql immutable as
$$ select '00000000-0000-0000-0000-00000000ad00'::uuid $$;
create function public._claim(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform public._claim(p); set local role authenticated; end $$;
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
create function public._pin(sol uuid) returns text language sql security definer set search_path = public as
$$ select pin_coleta::text from solicitacoes where id = sol $$;
create function public._errado(pin text) returns text language sql immutable as
$$ select lpad(((pin::int + 1) % 10000)::text, 4, '0') $$;
create function public._guc(k text) returns uuid language sql stable as $$ select current_setting(k)::uuid $$;
grant execute on function public._ger(int), public._cat(int), public._pon(int), public._pto(int), public._adm(),
  public._claim(uuid), public._as(uuid), public._pendente(uuid), public._guc(text), public._errado(text) to authenticated;

insert into auth.users (id) select public._ger(g) from generate_series(1, 5) g;
insert into perfis (id, papel, nome) select public._ger(g), 'gerador', 'Ger ' || g from generate_series(1, 5) g;
insert into geradores (perfil_id) select public._ger(g) from generate_series(1, 5) g;
insert into auth.users (id) select public._pon(g) from generate_series(1, 2) g;
insert into perfis (id, papel, nome) select public._pon(g), 'ponto', 'Pon ' || g from generate_series(1, 2) g;
insert into auth.users (id) values (public._adm());
insert into perfis (id, papel, nome) values (public._adm(), 'admin', 'Adm');
insert into materiais (id, codigo, nome, categoria) values (1, 'papel', 'Papel', 'papel'), (2, 'papelao', 'Papelao', 'papel'),
  (3, 'pet', 'PET', 'plastico') on conflict do nothing;
insert into pontos_coleta (id, perfil_id, nome, logradouro, cidade, uf, localizacao, ativo) values
  (public._pto(1), public._pon(1), 'P1', 'Rua 1', 'X', 'SP', st_setsrid(st_makepoint(10, 50.02), 4326)::geography, true),
  (public._pto(2), public._pon(2), 'P2', 'Rua 2', 'X', 'SP', st_setsrid(st_makepoint(10, 50.03), 4326)::geography, true),
  (public._pto(3), null,           'P3', 'Rua 3', 'X', 'SP', st_setsrid(st_makepoint(10, 50.04), 4326)::geography, false);
insert into ponto_precos (ponto_id, material_id, preco_kg) values (public._pto(1), 1, 0.35), (public._pto(1), 2, 1.60);

select public._mkcat(1, 50, 500);
select public._mkcat(2, 60, 500);
select public._mkcat(3, 61, 500);
select public._mkcat(4, 52, 1000);
select public._mkcat(5, 52, 2000);
select public._mkcat(6, 53, 1000);
select public._mkcat(9, 62, 500, 10, 'offline', 'pendente');

-- ---------- permissoes de funcao ----------
select ok(has_function_privilege('authenticated', 'public.alternar_disponibilidade(boolean)', 'execute'), 'authenticated executa alternar_disponibilidade');
select ok(has_function_privilege('authenticated', 'public.atualizar_localizacao(float8,float8,uuid)', 'execute'), 'authenticated executa atualizar_localizacao');
select ok(has_function_privilege('authenticated', 'public.iniciar_rota(uuid)', 'execute'), 'authenticated executa iniciar_rota');
select ok(has_function_privilege('authenticated', 'public.avancar_parada(uuid,text,text,text)', 'execute'), 'authenticated executa avancar_parada');
select ok(has_function_privilege('authenticated', 'public.registrar_entrega(uuid,jsonb)', 'execute'), 'authenticated executa registrar_entrega');
select ok(has_function_privilege('authenticated', 'public.cancelar_solicitacao(uuid,text)', 'execute'), 'authenticated executa cancelar_solicitacao');
select ok(has_function_privilege('authenticated', 'public.trocar_ponto_destino(uuid,uuid)', 'execute'), 'authenticated executa trocar_ponto_destino');
select ok(has_function_privilege('authenticated', 'public.avaliar(uuid,int,text)', 'execute'), 'authenticated executa avaliar');
select ok(has_function_privilege('authenticated', 'public.resetar_demo()', 'execute'), 'authenticated executa resetar_demo (RPC valida admin)');
select ok(not has_function_privilege('anon', 'public.avancar_parada(uuid,text,text,text)', 'execute'), 'anon nao executa avancar_parada');
select ok(not has_function_privilege('anon', 'public.registrar_entrega(uuid,jsonb)', 'execute'), 'anon nao executa registrar_entrega');
select ok(not has_function_privilege('anon', 'public.resetar_demo()', 'execute'), 'anon nao executa resetar_demo');
select ok(not has_function_privilege('authenticated', 'public._travar_rota(uuid)', 'execute'), 'helper _travar_rota e interno');
select ok(not has_function_privilege('authenticated', 'public._promover_proxima_parada(uuid)', 'execute'), 'helper _promover_proxima_parada e interno');
select ok(not has_function_privilege('authenticated', 'public._apos_remocao_parada(uuid)', 'execute'), 'helper _apos_remocao_parada e interno');
select ok(not has_function_privilege('authenticated', 'public.limpar_localizacoes_antigas()', 'execute'), 'limpeza de localizacoes e interna');
select ok(not has_table_privilege('anon', 'public.posicoes_atendimento', 'select'), 'anon nao le posicoes_atendimento');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'posicoes_atendimento'), 'posicoes_atendimento publicada no Realtime');
select ok(exists (select 1 from cron.job where jobname = 'kaptalixo-limpar-localizacoes' and command like '%limpar_localizacoes_antigas%'), 'job de retencao de 7 dias agendado');

-- ---------- alternar_disponibilidade (UC14, RN10) ----------
reset role; select public._as(public._ger(1));
select throws_ok($$select public.alternar_disponibilidade(true)$$, 'P0001', 'sem_permissao', 'gerador nao altera disponibilidade');
reset role; select public._claim(null);
select throws_ok($$select public.alternar_disponibilidade(true)$$, 'P0001', 'sem_permissao', 'sem login nao altera disponibilidade');
reset role; select public._as(public._cat(9));
select throws_ok($$select public.alternar_disponibilidade(true)$$, 'P0001', 'cadastro_nao_aprovado', 'RN10: catador pendente nao fica disponivel');
reset role;
select is((select situacao::text from catadores where perfil_id = public._cat(9)), 'offline', 'RN10: pendente segue offline');
select public._as(public._cat(2));
select throws_ok($$select public.alternar_disponibilidade(null)$$, 'P0001', 'parametro_invalido', 'parametro nulo invalido');
select is(public.alternar_disponibilidade(false)::text, 'offline', 'aprovado fica offline');
select is(public.alternar_disponibilidade(true)::text, 'disponivel', 'aprovado fica disponivel');
reset role;
select is((select situacao::text from catadores where perfil_id = public._cat(2)), 'disponivel', 'situacao gravada');
update catadores set situacao = 'em_rota' where perfil_id = public._cat(2);
select public._as(public._cat(2));
select throws_ok($$select public.alternar_disponibilidade(false)$$, 'P0001', 'catador_em_rota', 'em rota nao alterna');
reset role;
update catadores set situacao = 'disponivel' where perfil_id = public._cat(2);

-- ---------- atualizar_localizacao ----------
select public._as(public._ger(1));
select throws_ok($$select public.atualizar_localizacao(61, 10)$$, 'P0001', 'sem_permissao', 'gerador nao envia posicao de catador');
reset role; select public._as(public._cat(9));
select throws_ok($$select public.atualizar_localizacao(62, 10)$$, 'P0001', 'catador_indisponivel', 'catador offline nao envia posicao');
reset role; select public._as(public._cat(3));
select throws_ok($$select public.atualizar_localizacao(95, 10)$$, 'P0001', 'parametro_invalido', 'latitude invalida');
select throws_ok($$select public.atualizar_localizacao(61, null)$$, 'P0001', 'parametro_invalido', 'longitude nula invalida');
select throws_ok($$select public.atualizar_localizacao(61, 10, gen_random_uuid())$$, 'P0001', 'rota_inexistente', 'rota inexistente');
select lives_ok($$select public.atualizar_localizacao(61.001, 10.001)$$, 'catador disponivel atualiza posicao');
reset role;
select is(round(st_y(localizacao_atual::geometry)::numeric, 3), 61.001, 'posicao atual gravada') from catadores where perfil_id = public._cat(3);
select is((select count(*)::int from localizacoes_catador where catador_id = public._cat(3)), 1, 'historico: 1 ponto gravado');
select public._as(public._cat(3));
select public.atualizar_localizacao(61.002, 10.001);
reset role;
select is((select count(*)::int from localizacoes_catador where catador_id = public._cat(3)), 1, 'historico amostrado: 2a chamada em < 10 s nao grava');
update localizacoes_catador set registrada_em = now() - interval '1 minute' where catador_id = public._cat(3);
select public._as(public._cat(3));
select public.atualizar_localizacao(61.003, 10.001);
reset role;
select is((select count(*)::int from localizacoes_catador where catador_id = public._cat(3)), 2, 'historico: grava de novo apos 10 s');
select is(round(st_y(localizacao_atual::geometry)::numeric, 3), 61.003, 'posicao atual sempre atualiza') from catadores where perfil_id = public._cat(3);

-- ---------- P-009: limites de criar_solicitacao ----------
select public._as(public._ger(3));
select throws_ok($$select public.criar_solicitacao(53, 10, repeat('x', 201), 2)$$, 'P0001', 'parametro_invalido', 'P-009: endereco_texto > 200');
select throws_ok($$select public.criar_solicitacao(53, 10, 'x', 2, 'M', '{}', repeat('x', 501))$$, 'P0001', 'parametro_invalido', 'P-009: observacao > 500');
select throws_ok($$select public.criar_solicitacao(53, 10, 'x', 2, 'M', '{}', null, 'http://a.b/c.jpg')$$, 'P0001', 'parametro_invalido', 'P-009: foto sem https');
select throws_ok($$select public.criar_solicitacao(53, 10, 'x', 2, 'M', '{}', null, 'javascript:alert(1)')$$, 'P0001', 'parametro_invalido', 'P-009: foto com esquema perigoso');
select throws_ok($$select public.criar_solicitacao(53, 10, 'x', 2, 'M', '{}', null, 'https://a.b/c d.jpg')$$, 'P0001', 'parametro_invalido', 'P-009: foto com espaco');
select throws_ok($$select public.criar_solicitacao(53, 10, 'x', 2, 'M', array_fill(1::smallint, array[21]))$$, 'P0001', 'parametro_invalido', 'P-009: mais de 20 materiais');
reset role;
select is((select count(*)::int from solicitacoes where gerador_id = public._ger(3)), 0, 'P-009: validacoes nao criam nada');
-- P-009: parametro raios_busca_m ausente cai no padrao
delete from parametros where chave = 'raios_busca_m';
select public._as(public._ger(3));
select set_config('t.s6', public.criar_solicitacao(53, 10, repeat('x', 200), 2, 'M', array_fill(1::smallint, array[20]), repeat('o', 500), 'https://a.b/f.jpg')::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.s6')::uuid)), public._cat(6), 'P-009: sem raios_busca_m usa [3000,5000,8000] e ofera ao catador a 1 km');
select ok((select pin_coleta ~ '^[0-9]{4}$' from solicitacoes where id = current_setting('t.s6')::uuid), 'P-009: PIN de 4 digitos (gen_random_bytes)');

-- ---------- fluxo principal: S1 (real) + S2 (fixture) na rota de C1 ----------
select public._as(public._ger(1));
select set_config('t.s1', public.criar_solicitacao(50, 10, 'Rua A, 1', 3, 'M', array[1, 2]::smallint[], 'obs', 'https://a.b/f.jpg')::text, true);
reset role;
select public._as(public._cat(1));
select set_config('t.r', public.aceitar_oferta(public._pendente(current_setting('t.s1')::uuid))::text, true);
reset role;
select set_config('t.s2', gen_random_uuid()::text, true);
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id)
values (current_setting('t.s2')::uuid, public._ger(2), st_setsrid(st_makepoint(10, 50.005), 4326)::geography, 2, 'M', 10, 'aceita', '4321', public._cat(1));
insert into ofertas (solicitacao_id, catador_id, ordem, status, expira_em, respondida_em)
values (current_setting('t.s2')::uuid, public._cat(1), 1, 'aceita', now(), now());
insert into rota_paradas (rota_id, ordem, tipo, solicitacao_id, localizacao)
select current_setting('t.r')::uuid, 2, 'coleta', id, localizacao from solicitacoes where id = current_setting('t.s2')::uuid;
insert into rota_paradas (rota_id, ordem, tipo, ponto_id, localizacao)
select current_setting('t.r')::uuid, 3, 'descarte', id, localizacao from pontos_coleta where id = public._pto(2);
update rotas set ponto_destino_id = public._pto(2), polyline = 'abc', alternativas_ponto = '[{"ponto_id":"x","score":1}]'::jsonb
 where id = current_setting('t.r')::uuid;
select set_config('t.p1', (select id::text from rota_paradas where rota_id = current_setting('t.r')::uuid and ordem = 1), true);
select set_config('t.p2', (select id::text from rota_paradas where rota_id = current_setting('t.r')::uuid and ordem = 2), true);
select set_config('t.pd', (select id::text from rota_paradas where rota_id = current_setting('t.r')::uuid and ordem = 3), true);
select set_config('t.pin1', public._pin(current_setting('t.s1')::uuid), true);

select is((select status::text from rotas where id = current_setting('t.r')::uuid), 'planejada', 'rota nasce planejada');

-- P-005: rota aberta mostra polyline/alternativas ao dono
select public._as(public._cat(1));
select is((select polyline from v_rota_catador where id = current_setting('t.r')::uuid), 'abc', 'P-005: rota planejada mostra polyline ao catador');
select ok((select alternativas_ponto is not null from v_rota_catador where id = current_setting('t.r')::uuid), 'P-005: rota planejada mostra alternativas');
select throws_ok(format($$select public.avancar_parada(%L, 'cheguei')$$, current_setting('t.p1')), 'P0001', 'rota_invalida', 'avancar_parada em rota planejada falha');
reset role; select public._as(public._pon(2));
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'rota_invalida', 'registrar_entrega em rota planejada falha');

-- posicao atual do gerador (P-004 f)
reset role;
select is((select count(*)::int from posicoes_atendimento where solicitacao_id in (current_setting('t.s1')::uuid, current_setting('t.s2')::uuid)), 2, 'posicao criada no aceite (trigger)');
select public._as(public._ger(1));
select is((select count(*)::int from posicoes_atendimento), 1, 'gerador 1 ve so a posicao da propria solicitacao');
reset role; select public._as(public._ger(3));
select is((select count(*)::int from posicoes_atendimento), 0, 'gerador alheio nao ve posicao');
reset role; select public._as(public._cat(1));
select is((select count(*)::int from posicoes_atendimento), 0, 'catador nao le posicoes_atendimento (RLS)');

-- iniciar_rota
reset role; select public._as(public._ger(1));
select throws_ok(format($$select public.iniciar_rota(%L)$$, current_setting('t.r')), 'P0001', 'sem_permissao', 'gerador nao inicia rota');
reset role; select public._as(public._cat(2));
select throws_ok(format($$select public.iniciar_rota(%L)$$, current_setting('t.r')), 'P0001', 'rota_inexistente', 'catador alheio nao inicia rota');
select throws_ok($$select public.iniciar_rota(gen_random_uuid())$$, 'P0001', 'rota_inexistente', 'rota inexistente');
reset role;
select is((select status::text from rotas where id = current_setting('t.r')::uuid), 'planejada', 'tentativas indevidas nao alteram a rota');
select public._as(public._cat(1));
select lives_ok(format($$select public.iniciar_rota(%L)$$, current_setting('t.r')), 'catador dono inicia a rota');
select throws_ok(format($$select public.iniciar_rota(%L)$$, current_setting('t.r')), 'P0001', 'rota_invalida', 'iniciar duas vezes falha');
reset role;
select is((select status::text from rotas where id = current_setting('t.r')::uuid), 'em_andamento', 'rota em_andamento');
select ok((select iniciada_em is not null from rotas where id = current_setting('t.r')::uuid), 'iniciada_em gravada');
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'a_caminho', '1a solicitacao a_caminho');
select is((select status::text from solicitacoes where id = current_setting('t.s2')::uuid), 'aceita', '2a solicitacao segue aceita');
select is((select status::text from rota_paradas where id = current_setting('t.p1')::uuid), 'a_caminho', '1a parada a_caminho');

-- atualizar_localizacao com rota alimenta a posicao do gerador
select public._as(public._cat(2));
select throws_ok(format($$select public.atualizar_localizacao(50.5, 10, %L)$$, current_setting('t.r')), 'P0001', 'rota_inexistente', 'rota de outro catador rejeitada');
reset role; select public._as(public._cat(1));
select lives_ok(format($$select public.atualizar_localizacao(50.01, 10, %L)$$, current_setting('t.r')), 'catador em rota envia posicao');
reset role; select public._as(public._ger(1));
select is((select round(lat::numeric, 2) from posicoes_atendimento), 50.01, 'gerador ve a posicao atual do catador');
reset role;
select is((select rota_id from localizacoes_catador where catador_id = public._cat(1) order by id desc limit 1), current_setting('t.r')::uuid, 'historico liga a posicao a rota');

-- trocar_ponto_destino (UC07)
select public._as(public._ger(1));
select throws_ok(format($$select public.trocar_ponto_destino(%L, %L)$$, current_setting('t.r'), public._pto(1)), 'P0001', 'sem_permissao', 'gerador nao troca ponto');
reset role; select public._as(public._cat(2));
select throws_ok(format($$select public.trocar_ponto_destino(%L, %L)$$, current_setting('t.r'), public._pto(1)), 'P0001', 'rota_inexistente', 'catador alheio nao troca ponto');
reset role; select public._as(public._cat(1));
select throws_ok(format($$select public.trocar_ponto_destino(%L, gen_random_uuid())$$, current_setting('t.r')), 'P0001', 'ponto_inexistente', 'ponto inexistente');
select throws_ok(format($$select public.trocar_ponto_destino(%L, %L)$$, current_setting('t.r'), public._pto(3)), 'P0001', 'ponto_inexistente', 'ponto inativo nao serve de destino');
reset role;
select is((select ponto_destino_id from rotas where id = current_setting('t.r')::uuid), public._pto(2), 'tentativas invalidas nao alteram o destino');
select set_config('t.v0', (select versao::text from rotas where id = current_setting('t.r')::uuid), true);
select public._as(public._cat(1));
select lives_ok(format($$select public.trocar_ponto_destino(%L, %L)$$, current_setting('t.r'), public._pto(1)), 'catador troca o ponto de destino');
reset role;
select is((select ponto_destino_id from rotas where id = current_setting('t.r')::uuid), public._pto(1), 'destino atualizado');
select ok((select versao > current_setting('t.v0')::int from rotas where id = current_setting('t.r')::uuid), 'versao incrementa (sinaliza recalculo)');
select is((select ponto_id from rota_paradas where id = current_setting('t.pd')::uuid), public._pto(1), 'parada de descarte acompanha o novo ponto');

-- avancar_parada: permissoes e validacoes
select public._as(public._cat(2));
select throws_ok(format($$select public.avancar_parada(%L, 'cheguei')$$, current_setting('t.p1')), 'P0001', 'parada_inexistente', 'catador alheio nao avanca parada');
reset role; select public._as(public._ger(1));
select throws_ok(format($$select public.avancar_parada(%L, 'cheguei')$$, current_setting('t.p1')), 'P0001', 'sem_permissao', 'gerador nao avanca parada');
reset role; select public._as(public._cat(1));
select throws_ok($$select public.avancar_parada(gen_random_uuid(), 'cheguei')$$, 'P0001', 'parada_inexistente', 'parada inexistente');
select throws_ok(format($$select public.avancar_parada(%L, 'xyz')$$, current_setting('t.p1')), 'P0001', 'parametro_invalido', 'acao invalida');
select throws_ok(format($$select public.avancar_parada(%L, 'concluir', '1234')$$, current_setting('t.p1')), 'P0001', 'parada_invalida', 'concluir sem ter chegado falha');
select throws_ok(format($$select public.avancar_parada(%L, 'cheguei')$$, current_setting('t.pd')), 'P0001', 'coletas_pendentes', 'descarte: cheguei com coletas pendentes falha');
select throws_ok(format($$select public.avancar_parada(%L, 'concluir', '1234')$$, current_setting('t.pd')), 'P0001', 'parada_invalida', 'descarte nao conclui por avancar_parada');
reset role; select public._as(public._pon(1));
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'coletas_pendentes', 'entrega com coletas pendentes falha');

-- cheguei
reset role; select public._as(public._cat(1));
select is(public.avancar_parada(current_setting('t.p1')::uuid, 'cheguei')->>'resultado', 'ok', 'cheguei na 1a parada');
select throws_ok(format($$select public.avancar_parada(%L, 'cheguei')$$, current_setting('t.p2')), 'P0001', 'parada_invalida', 'nao chega na 2a parada estando no_local na 1a');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'no_local', 'solicitacao no_local');
select is((select status::text from rota_paradas where id = current_setting('t.p1')::uuid), 'no_local', 'parada no_local');
select ok((select chegou_em is not null from rota_paradas where id = current_setting('t.p1')::uuid), 'chegou_em gravado');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(1) and tipo = 'catador_chegou'), 1, 'gerador avisado da chegada');

-- RN08: PIN
select public._as(public._cat(1));
select throws_ok(format($$select public.avancar_parada(%L, 'concluir')$$, current_setting('t.p1')), 'P0001', 'parametro_invalido', 'concluir sem PIN');
select throws_ok(format($$select public.avancar_parada(%L, 'concluir', 'abc')$$, current_setting('t.p1')), 'P0001', 'parametro_invalido', 'PIN mal formado');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'catador nao le pin_coleta');
select throws_ok($$select pin_coleta from v_solicitacao_catador$$, '42703', null, 'view do catador nao tem pin_coleta');
select is(public.avancar_parada(current_setting('t.p1')::uuid, 'concluir', public._errado(current_setting('t.pin1')))->>'resultado', 'pin_incorreto', 'RN08: PIN errado (1)');
select is((public.avancar_parada(current_setting('t.p1')::uuid, 'concluir', public._errado(current_setting('t.pin1')))->>'tentativas_restantes')::int, 1, 'RN08: PIN errado (2) restam 1');
reset role;
select is((select pin_erros from solicitacoes where id = current_setting('t.s1')::uuid), 2, 'contador de erros persistido (nao desfeito por excecao)');
select is((select status::text from rota_paradas where id = current_setting('t.p1')::uuid), 'no_local', 'PIN errado nao conclui a parada');
select public._as(public._cat(1));
select is(public.avancar_parada(current_setting('t.p1')::uuid, 'concluir', public._errado(current_setting('t.pin1')))->>'resultado', 'pin_bloqueado', 'RN08: 3o erro bloqueia');
reset role;
select ok((select bloqueio_pin_ate > now() + interval '100 seconds' and pin_erros = 0 from solicitacoes where id = current_setting('t.s1')::uuid), 'bloqueio de ~2 min gravado e contador zerado');
select is((select count(*)::int from notificacoes where perfil_id = public._adm() and tipo = 'alerta_pin_bloqueado'), 1, 'alerta ao admin');
select public._as(public._cat(1));
select is(public.avancar_parada(current_setting('t.p1')::uuid, 'concluir', current_setting('t.pin1'))->>'resultado', 'pin_bloqueado', 'PIN correto durante o bloqueio nao conclui');
select ok(not (public.avancar_parada(current_setting('t.p1')::uuid, 'concluir', current_setting('t.pin1')) ? 'pin'), 'resposta nunca traz o PIN');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'no_local', 'bloqueio: solicitacao segue no_local');
update solicitacoes set bloqueio_pin_ate = now() - interval '1 second' where id = current_setting('t.s1')::uuid;
select public._as(public._cat(1));
select is(public.avancar_parada(current_setting('t.p1')::uuid, 'concluir', current_setting('t.pin1'))->>'resultado', 'ok', 'RN08: PIN correto apos o bloqueio conclui');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'coletada', 'solicitacao coletada');
select is((select status::text from rota_paradas where id = current_setting('t.p1')::uuid), 'concluida', 'parada concluida');
select is((select status::text from rota_paradas where id = current_setting('t.p2')::uuid), 'a_caminho', 'proxima parada a_caminho');
select is((select status::text from solicitacoes where id = current_setting('t.s2')::uuid), 'a_caminho', 'proxima solicitacao a_caminho');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(1) and tipo = 'coleta_confirmada'), 1, 'gerador avisado da coleta');
select is((select count(*)::int from posicoes_atendimento where solicitacao_id = current_setting('t.s1')::uuid), 0, 'posicao do catador some apos coletada');
select is((select count(*)::int from posicoes_atendimento where solicitacao_id = current_setting('t.s2')::uuid), 1, 'posicao da 2a solicitacao segue ativa');
select public._as(public._cat(1));
select is((select count(*)::int from solicitacoes where id = current_setting('t.s1')::uuid), 0, 'catador perde acesso a solicitacao coletada');
select ok((select endereco_texto is null and lat is null from v_solicitacao_catador where id = current_setting('t.s1')::uuid), 'view do catador oculta endereco/coordenadas apos coletada');

-- pular parada (gerador ausente)
reset role; select public._as(public._ger(2));
select throws_ok(format($$select public.avancar_parada(%L, 'pular')$$, current_setting('t.p2')), 'P0001', 'sem_permissao', 'gerador nao pula parada');
reset role; select public._as(public._cat(2));
select throws_ok(format($$select public.avancar_parada(%L, 'pular')$$, current_setting('t.p2')), 'P0001', 'parada_inexistente', 'catador alheio nao pula parada');
reset role; select set_config('t.v1', (select versao::text from rotas where id = current_setting('t.r')::uuid), true);
select public._as(public._cat(1));
select is(public.avancar_parada(current_setting('t.p2')::uuid, 'pular', null, 'gerador ausente')->>'resultado', 'ok', 'catador pula a 2a parada');
reset role;
select is((select status::text from rota_paradas where id = current_setting('t.p2')::uuid), 'pulada', 'parada pulada');
select ok((select catador_id is null and status in ('buscando','sem_catador') from solicitacoes where id = current_setting('t.s2')::uuid), 'solicitacao pulada volta a fila sem catador');
select is((select count(*)::int from ofertas where solicitacao_id = current_setting('t.s2')::uuid and catador_id = public._cat(1)), 1, 'catador que pulou nao recebe nova oferta dessa solicitacao');
select is((select status::text from rotas where id = current_setting('t.r')::uuid), 'em_andamento', 'rota segue (ha coleta concluida)');
select ok((select versao > current_setting('t.v1')::int from rotas where id = current_setting('t.r')::uuid), 'versao incrementa ao pular');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(2) and tipo = 'catador_nao_atendeu'), 1, 'gerador avisado');
select is((select count(*)::int from posicoes_atendimento where solicitacao_id = current_setting('t.s2')::uuid), 0, 'posicao removida ao devolver a fila');

-- descarte
select public._as(public._cat(1));
select is(public.avancar_parada(current_setting('t.pd')::uuid, 'cheguei')->>'resultado', 'ok', 'cheguei no ponto de descarte');
reset role;
select is((select status::text from rota_paradas where id = current_setting('t.pd')::uuid), 'no_local', 'parada de descarte no_local');

-- ---------- registrar_entrega (RN11) ----------
select public._as(public._ger(1));
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'sem_permissao', 'gerador nao registra entrega');
reset role; select public._as(public._cat(1));
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'sem_permissao', 'catador nao registra a propria entrega');
reset role; select public._as(public._pon(2));
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'rota_inexistente', 'operador de outro ponto nao registra');
reset role; select public._as(public._pon(1));
select throws_ok(format($$select public.registrar_entrega(%L, '[]')$$, current_setting('t.r')), 'P0001', 'parametro_invalido', 'itens vazios');
select throws_ok(format($$select public.registrar_entrega(%L, '{}')$$, current_setting('t.r')), 'P0001', 'parametro_invalido', 'itens nao e array');
select throws_ok(format($$select public.registrar_entrega(%L, '[1]')$$, current_setting('t.r')), 'P0001', 'parametro_invalido', 'item nao e objeto');
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":0}]')$$, current_setting('t.r')), 'P0001', 'parametro_invalido', 'peso zero');
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1}]')$$, current_setting('t.r')), 'P0001', 'parametro_invalido', 'peso ausente');
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":"x","peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'parametro_invalido', 'material_id nao numerico');
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":3,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'material_sem_preco', 'material sem preco no ponto');
reset role;
select is((select count(*)::int from entregas where rota_id = current_setting('t.r')::uuid), 0, 'tentativas invalidas nao criam entrega');
select is((select status::text from rotas where id = current_setting('t.r')::uuid), 'em_andamento', 'nem concluem a rota');

select public._as(public._pon(1));
select set_config('t.e', public.registrar_entrega(current_setting('t.r')::uuid,
  '[{"material_id":1,"peso_kg":10.0},{"material_id":2,"peso_kg":3.25},{"material_id":1,"peso_kg":0.5}]')::text, true);
select is((select valor_total from entregas where id = current_setting('t.e')::uuid), 8.88::numeric, 'RN11: valor = soma(kg x preco) = 10,5x0,35 (3,68) + 3,25x1,60 (5,20)');
select is((select peso_total_kg from entregas where id = current_setting('t.e')::uuid), 13.75::numeric, 'peso total 13,75 kg');
select is((select count(*)::int from entrega_itens where entrega_id = current_setting('t.e')::uuid), 2, 'pesos do mesmo material somam em 1 item');
select is((select valor from entrega_itens where entrega_id = current_setting('t.e')::uuid and material_id = 1), 3.68::numeric, 'item 1: 10,5 kg x 0,35 = 3,68');
select is((select preco_kg from entrega_itens where entrega_id = current_setting('t.e')::uuid and material_id = 2), 1.60::numeric, 'item 2 grava o preco vigente');
select is((select count(*)::int from entregas), 1, 'operador do ponto le a entrega');
select throws_ok(format($$select public.registrar_entrega(%L, '[{"material_id":1,"peso_kg":1}]')$$, current_setting('t.r')), 'P0001', 'rota_invalida', 'entrega duplicada rejeitada');
reset role;
select is((select status::text from rotas where id = current_setting('t.r')::uuid), 'concluida', 'estado final: rota concluida');
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'entregue', 'estado final: solicitacao entregue');
select is((select situacao::text from catadores where perfil_id = public._cat(1)), 'disponivel', 'estado final: catador disponivel');
select is((select status::text from rota_paradas where id = current_setting('t.pd')::uuid), 'concluida', 'parada de descarte concluida');
select isnt((select status::text from solicitacoes where id = current_setting('t.s2')::uuid), 'entregue', 'solicitacao pulada nao vira entregue');
select ok((select registrada_por = public._pon(1) from entregas where id = current_setting('t.e')::uuid), 'entrega registrada pelo operador');
select is((select count(*)::int from notificacoes where perfil_id = public._cat(1) and tipo = 'entrega_registrada'), 1, 'catador notificado da entrega');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(1) and tipo = 'coleta_entregue'), 1, 'gerador notificado da entrega');
select public._as(public._cat(1));
select is((select count(*)::int from entregas), 1, 'catador dono le a entrega');
select is((select count(*)::int from entrega_itens), 2, 'catador dono le os itens');
select ok((select polyline is null and alternativas_ponto is null from v_rota_catador where id = current_setting('t.r')::uuid), 'P-005: rota concluida nao devolve polyline/alternativas');
reset role; select public._as(public._cat(2));
select is((select count(*)::int from entregas), 0, 'catador alheio nao le entregas');
reset role; select public._as(public._pon(2));
select is((select count(*)::int from entregas), 0, 'operador de outro ponto nao le entregas');

-- ---------- avaliar (UC13, RN12) ----------
reset role;
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, tamanho, peso_estimado_kg, status, pin_coleta, catador_id)
values (gen_random_uuid(), public._ger(5), st_setsrid(st_makepoint(10, 54), 4326)::geography, 1, 'M', 5, 'coletada', '0000', public._cat(1));
select set_config('t.s3', (select id::text from solicitacoes where gerador_id = public._ger(5)), true);
select public._as(public._ger(3));
select throws_ok(format($$select public.avaliar(%L, 5)$$, current_setting('t.s1')), 'P0001', 'solicitacao_inexistente', 'estranho nao avalia');
reset role; select public._as(public._pon(1));
select throws_ok(format($$select public.avaliar(%L, 5)$$, current_setting('t.s1')), 'P0001', 'sem_permissao', 'ponto nao avalia');
reset role; select public._as(public._ger(1));
select throws_ok(format($$select public.avaliar(%L, 0)$$, current_setting('t.s1')), 'P0001', 'parametro_invalido', 'nota 0 invalida');
select throws_ok(format($$select public.avaliar(%L, 6)$$, current_setting('t.s1')), 'P0001', 'parametro_invalido', 'nota 6 invalida');
select throws_ok(format($$select public.avaliar(%L, 5, repeat('x', 501))$$, current_setting('t.s1')), 'P0001', 'parametro_invalido', 'comentario > 500');
reset role; select public._as(public._ger(2));
select throws_ok(format($$select public.avaliar(%L, 5)$$, current_setting('t.s2')), 'P0001', 'avaliacao_indisponivel', 'RN12: so apos a coleta');
reset role; select public._as(public._ger(1));
select lives_ok(format($$select public.avaliar(%L, 4, 'ok')$$, current_setting('t.s1')), 'gerador avalia o catador');
select throws_ok(format($$select public.avaliar(%L, 5)$$, current_setting('t.s1')), 'P0001', 'avaliacao_duplicada', 'RN12: avaliacao duplicada rejeitada');
reset role;
select is((select avaliacao_media from catadores where perfil_id = public._cat(1)), 4.00::numeric, 'media do catador atualizada');
select is((select total_avaliacoes from catadores where perfil_id = public._cat(1)), 1, 'total do catador = 1');
select public._as(public._cat(1));
select lives_ok(format($$select public.avaliar(%L, 5)$$, current_setting('t.s1')), 'catador avalia o gerador');
select throws_ok(format($$select public.avaliar(%L, 1)$$, current_setting('t.s1')), 'P0001', 'avaliacao_duplicada', 'catador nao avalia duas vezes');
select is((select count(*)::int from avaliacoes), 2, 'catador le as 2 avaliacoes da solicitacao');
reset role;
select is((select avaliacao_media from geradores where perfil_id = public._ger(1)), 5.00::numeric, 'media do gerador atualizada');
select public._as(public._ger(5));
select lives_ok(format($$select public.avaliar(%L, 2)$$, current_setting('t.s3')), 'avaliacao de solicitacao coletada (ainda nao entregue)');
reset role;
select is((select avaliacao_media from catadores where perfil_id = public._cat(1)), 3.00::numeric, 'media do catador = (4+2)/2');
select is((select total_avaliacoes from catadores where perfil_id = public._cat(1)), 2, 'total do catador = 2');
select public._as(public._ger(3));
select is((select count(*)::int from avaliacoes), 0, 'usuario alheio nao le avaliacoes');
reset role; select public._as(public._ger(1));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.s1')), 'P0001', 'solicitacao_nao_cancelavel', 'RN09: gerador nao cancela solicitacao entregue');
reset role; select public._as(public._cat(1));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.s1')), 'P0001', 'solicitacao_nao_cancelavel', 'catador nao cancela solicitacao entregue');
reset role; select public._as(public._ger(5));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.s3')), 'P0001', 'solicitacao_nao_cancelavel', 'RN09: gerador nao cancela solicitacao coletada');

-- ---------- cancelar_solicitacao (UC12, RN09) ----------
-- X: gerador cancela antes do aceite (sem efeito colateral)
reset role; select public._as(public._ger(4));
select set_config('t.sx', public.criar_solicitacao(52, 10, 'Rua X', 2)::text, true);
reset role;
select set_config('t.ox', public._pendente(current_setting('t.sx')::uuid)::text, true);
select is((select catador_id from ofertas where id = current_setting('t.ox')::uuid), public._cat(4), 'X: oferta ao catador 4');
select public._as(public._ger(3));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sx')), 'P0001', 'solicitacao_inexistente', 'X: gerador alheio nao cancela');
reset role; select public._as(public._cat(5));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sx')), 'P0001', 'solicitacao_inexistente', 'X: catador sem vinculo nao cancela');
reset role; select public._as(public._cat(4));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sx')), 'P0001', 'solicitacao_inexistente', 'X: catador com oferta pendente nao cancela (recusa a oferta)');
select throws_ok($$select public.cancelar_solicitacao(gen_random_uuid())$$, 'P0001', 'solicitacao_inexistente', 'X: solicitacao inexistente');
reset role; select public._as(public._pon(1));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sx')), 'P0001', 'sem_permissao', 'X: ponto nao cancela');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sx')::uuid), 'buscando', 'X: tentativas indevidas nao alteram');
select public._as(public._ger(4));
select lives_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sx')), 'X: gerador cancela antes do aceite');
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sx')), 'P0001', 'solicitacao_nao_cancelavel', 'X: cancelar duas vezes falha');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sx')::uuid), 'cancelada', 'X: solicitacao cancelada');
select is((select status::text from ofertas where id = current_setting('t.ox')::uuid), 'cancelada', 'X: oferta pendente cancelada');
select is((select situacao::text from catadores where perfil_id = public._cat(4)), 'disponivel', 'X: catador intacto');
select is((select count(*)::int from notificacoes where perfil_id = public._cat(4) and tipo = 'solicitacao_cancelada'), 0, 'X: sem aviso ao catador (sem efeito colateral)');
select public._as(public._cat(4));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.ox')), 'P0001', 'oferta_indisponivel', 'X: oferta cancelada nao pode ser aceita');

-- Y: gerador cancela depois do aceite
reset role; select public._as(public._ger(4));
select set_config('t.sy', public.criar_solicitacao(52, 10, 'Rua Y', 2)::text, true);
reset role; select public._as(public._cat(4));
select set_config('t.ry', public.aceitar_oferta(public._pendente(current_setting('t.sy')::uuid))::text, true);
reset role;
select is((select count(*)::int from posicoes_atendimento where solicitacao_id = current_setting('t.sy')::uuid), 1, 'Y: posicao criada no aceite');
select public._as(public._ger(4));
select lives_ok(format($$select public.cancelar_solicitacao(%L, '  mudei de ideia  ')$$, current_setting('t.sy')), 'Y: gerador cancela apos o aceite');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sy')::uuid), 'cancelada', 'Y: solicitacao cancelada');
select is((select motivo_cancelamento from solicitacoes where id = current_setting('t.sy')::uuid), 'mudei de ideia', 'Y: RN09 motivo gravado');
select is((select count(*)::int from eventos_solicitacao where solicitacao_id = current_setting('t.sy')::uuid and para_status = 'cancelada' and ator_id = public._ger(4)), 1, 'Y: RN09 acao registrada com o ator');
select is((select count(*)::int from notificacoes where perfil_id = public._cat(4) and tipo = 'solicitacao_cancelada'), 1, 'Y: RN09 catador avisado');
select is((select status::text from rotas where id = current_setting('t.ry')::uuid), 'cancelada', 'Y: rota sem coletas e cancelada');
select is((select situacao::text from catadores where perfil_id = public._cat(4)), 'disponivel', 'Y: catador volta a disponivel');
select is((select count(*)::int from posicoes_atendimento where solicitacao_id = current_setting('t.sy')::uuid), 0, 'Y: posicao removida');
select public._as(public._cat(4));
select ok((select polyline is null from v_rota_catador where id = current_setting('t.ry')::uuid), 'Y: P-005 rota cancelada sem polyline');

-- Z: catador cancela e a solicitacao volta a fila (RN09)
reset role; select public._as(public._ger(4));
select set_config('t.sz', public.criar_solicitacao(52, 10, 'Rua Z', 2)::text, true);
reset role; select public._as(public._cat(4));
select set_config('t.rz', public.aceitar_oferta(public._pendente(current_setting('t.sz')::uuid))::text, true);
select throws_ok(format($$select public.cancelar_solicitacao(%L, repeat('m', 201))$$, current_setting('t.sz')), 'P0001', 'parametro_invalido', 'Z: motivo > 200 invalido');
reset role; select public._as(public._cat(5));
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sz')), 'P0001', 'solicitacao_inexistente', 'Z: outro catador nao cancela');
reset role; select public._as(public._cat(4));
select lives_ok(format($$select public.cancelar_solicitacao(%L, 'quebrou o carrinho')$$, current_setting('t.sz')), 'Z: catador cancela');
select throws_ok(format($$select public.cancelar_solicitacao(%L)$$, current_setting('t.sz')), 'P0001', 'solicitacao_inexistente', 'Z: nao cancela de novo (ja nao e dele)');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.sz')::uuid), 'buscando', 'Z: solicitacao volta a buscando');
select ok((select catador_id is null and pin_erros = 0 from solicitacoes where id = current_setting('t.sz')::uuid), 'Z: sem catador atribuido');
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.sz')::uuid)), public._cat(5), 'Z: nova oferta vai a outro catador');
select is((select count(*)::int from ofertas where solicitacao_id = current_setting('t.sz')::uuid and catador_id = public._cat(4)), 1, 'Z: catador que cancelou nao recebe de novo');
select is((select tentativas_oferta from solicitacoes where id = current_setting('t.sz')::uuid), 2, 'Z: tentativas contam a nova oferta');
select is((select status::text from rotas where id = current_setting('t.rz')::uuid), 'cancelada', 'Z: rota cancelada');
select is((select situacao::text from catadores where perfil_id = public._cat(4)), 'disponivel', 'Z: catador volta a disponivel');
select is((select count(*)::int from notificacoes where perfil_id = public._ger(4) and tipo = 'catador_cancelou'), 1, 'Z: gerador avisado');
select public._as(public._ger(4));
select ok((select pin_coleta ~ '^[0-9]{4}$' from v_solicitacao_gerador where id = current_setting('t.sz')::uuid), 'Z: gerador segue lendo o proprio PIN');

-- ---------- retencao de localizacoes (7 dias) ----------
reset role;
insert into localizacoes_catador (catador_id, localizacao, registrada_em)
values (public._cat(2), st_setsrid(st_makepoint(10, 60), 4326)::geography, now() - interval '8 days'),
       (public._cat(2), st_setsrid(st_makepoint(10, 60), 4326)::geography, now() - interval '6 days');
select ok(public.limpar_localizacoes_antigas() >= 1, 'limpeza remove ao menos a posicao antiga');
select is((select count(*)::int from localizacoes_catador where catador_id = public._cat(2) and registrada_em < now() - interval '7 days'), 0, 'nada com mais de 7 dias');
select is((select count(*)::int from localizacoes_catador where catador_id = public._cat(2)), 1, 'posicao recente preservada');

-- ---------- resetar_demo (UC15) ----------
insert into demo_estado_catadores (catador_id, situacao, localizacao_atual)
values (public._cat(1), 'offline', st_setsrid(st_makepoint(10, 50.1), 4326)::geography)
on conflict (catador_id) do update set situacao = excluded.situacao, localizacao_atual = excluded.localizacao_atual;
select set_config('t.nperfis', (select count(*)::text from perfis), true);
select set_config('t.npontos', (select count(*)::text from pontos_coleta), true);
insert into parametros (chave, valor) values ('modo_demo', 'false'::jsonb) on conflict (chave) do update set valor = 'false'::jsonb;

select public._as(public._ger(1));
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'sem_permissao', 'gerador nao reseta a demo');
select throws_ok($$select count(*) from demo_estado_catadores$$, '42501', null, 'estado base da demo nao e legivel por authenticated');
reset role; select public._as(public._cat(1));
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'sem_permissao', 'catador nao reseta a demo');
reset role; select public._as(public._pon(1));
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'sem_permissao', 'ponto nao reseta a demo');
reset role; select public._claim(null);
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'sem_permissao', 'sem login nao reseta a demo');
reset role; select public._as(public._adm());
select throws_ok($$select public.resetar_demo()$$, 'P0001', 'modo_demo_desativado', 'admin com modo_demo=false nao reseta');
reset role;
select is((select count(*)::int from solicitacoes where id = current_setting('t.s1')::uuid), 1, 'tentativas negadas preservam os dados');
update parametros set valor = 'true'::jsonb where chave = 'modo_demo';
select public._as(public._adm());
select lives_ok($$select public.resetar_demo()$$, 'admin com modo_demo=true reseta');
reset role;
select is((select count(*)::int from solicitacoes), 0, 'reset: sem solicitacoes');
select is((select count(*)::int from rotas), 0, 'reset: sem rotas');
select is((select count(*)::int from entregas), 0, 'reset: sem entregas');
select is((select count(*)::int from avaliacoes), 0, 'reset: sem avaliacoes');
select is((select count(*)::int from notificacoes), 0, 'reset: sem notificacoes');
select is((select count(*)::int from localizacoes_catador), 0, 'reset: sem historico de posicoes');
select is((select avaliacao_media from catadores where perfil_id = public._cat(1)), 0.00::numeric, 'reset: media do catador zerada');
select is((select avaliacao_media from geradores where perfil_id = public._ger(1)), 0.00::numeric, 'reset: media do gerador zerada');
select is((select situacao::text from catadores where perfil_id = public._cat(1)), 'offline', 'reset: catador restaurado do estado base');
select is(round(st_y(localizacao_atual::geometry)::numeric, 2), 50.10, 'reset: posicao restaurada') from catadores where perfil_id = public._cat(1);
select is((select count(*)::int from perfis), current_setting('t.nperfis')::int, 'reset: perfis preservados');
select is((select count(*)::int from pontos_coleta), current_setting('t.npontos')::int, 'reset: pontos preservados');

select * from finish();
rollback;
