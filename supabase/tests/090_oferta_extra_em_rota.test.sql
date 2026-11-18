-- T1.10: oferta extra a catador em rota (UC10, RN05).
-- Autonomo: fixtures proprias longe do seed (lat 60) criadas dentro da transacao.
-- Geometria (base P0 = lat 60, lng 10): catador X em rota em P0; proxima parada S0 a 3000 m ao norte (az 0);
-- N1 = 1000 m ao norte (no caminho, desvio 0); N2 = 1000 m a leste (desvio ~1162 m, dentro);
-- N3 = 2000 m a leste (desvio ~2606 m, fora de 1500 m). D = catador disponivel 3000 m a oeste.
begin;
select plan(58);

-- ---------- fixtures ----------
create function public._g(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._c(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-0000-0000-00000000f0' || lpad(n::text, 2, '0'))::uuid $$;
create function public._claim(p uuid) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
create function public._as(p uuid) returns void language plpgsql as
$$ begin perform public._claim(p); set local role authenticated; end $$;
create function public._pt(d float8, az float8) returns geography language sql immutable as
$$ select st_project(st_setsrid(st_makepoint(10, 60), 4326)::geography, d, radians(az)) $$;
create function public._lat(d float8, az float8) returns float8 language sql immutable as
$$ select st_y(public._pt(d, az)::geometry) $$;
create function public._lng(d float8, az float8) returns float8 language sql immutable as
$$ select st_x(public._pt(d, az)::geometry) $$;
create function public._pendente(sol uuid) returns uuid language sql security definer set search_path = public as
$$ select id from ofertas where solicitacao_id = sol and status = 'pendente' $$;
create function public._busca(d float8, az float8, sacos int, raio int default 8000, excl uuid[] default '{}')
returns uuid[] language sql as
$$ select coalesce(array_agg(catador_id), '{}') from public.buscar_catadores_proximos(public._lat(d, az), public._lng(d, az), raio, sacos, excl, 10) $$;
grant execute on function public._g(int), public._c(int), public._claim(uuid), public._as(uuid), public._pendente(uuid),
  public._pt(float8, float8), public._lat(float8, float8), public._lng(float8, float8) to authenticated;

insert into auth.users (id) select public._g(n) from generate_series(1, 5) n;
insert into perfis (id, papel, nome) select public._g(n), 'gerador', 'Ger ' || n from generate_series(1, 5) n;
insert into geradores (perfil_id) select public._g(n) from generate_series(1, 5) n;
insert into auth.users (id) select public._c(n) from generate_series(1, 2) n;
insert into perfis (id, papel, nome) select public._c(n), 'catador', 'Cat ' || n from generate_series(1, 2) n;
-- X (1): em rota, em P0. D (2): disponivel, 3000 m a oeste.
insert into catadores (perfil_id, status_cadastro, capacidade_sacos, situacao, localizacao_atual) values
  (public._c(1), 'aprovado', 10, 'em_rota',    public._pt(0, 0)),
  (public._c(2), 'aprovado', 10, 'disponivel', public._pt(3000, 270));
insert into pontos_coleta (id, nome, logradouro, cidade, uf, localizacao)
values ('00000000-0000-0000-0000-0000000000b1', 'Ponto T', 'Rua T', 'X', 'SP', public._pt(6000, 0));
-- S0: coleta ja aceita pelo X, 2 sacos, 3000 m ao norte; rota em andamento com descarte a 6000 m ao norte
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, status, pin_coleta, catador_id)
values ('00000000-0000-0000-0000-0000000000a0', public._g(1), public._pt(3000, 0), 2, 'a_caminho', '1234', public._c(1));
insert into rotas (id, catador_id, status, ponto_destino_id, versao, iniciada_em)
values ('00000000-0000-0000-0000-0000000000c0', public._c(1), 'em_andamento', '00000000-0000-0000-0000-0000000000b1', 1, now());
insert into rota_paradas (id, rota_id, ordem, tipo, solicitacao_id, localizacao, status) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c0', 1, 'coleta', '00000000-0000-0000-0000-0000000000a0', public._pt(3000, 0), 'a_caminho');
insert into rota_paradas (id, rota_id, ordem, tipo, ponto_id, localizacao) values
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000c0', 2, 'descarte', '00000000-0000-0000-0000-0000000000b1', public._pt(6000, 0));
insert into materiais (id, codigo, nome, categoria) values (1, 'papel', 'Papel', 'papel') on conflict do nothing;

-- ---------- busca: candidato em rota dentro/fora do desvio (RN05) ----------
select is(public._busca(1000, 0, 3), array[public._c(1), public._c(2)], 'busca N1 (no caminho): X em rota vem antes de D (mais perto, sem desvio)');
select ok((select em_rota from public.buscar_catadores_proximos(public._lat(1000, 0), public._lng(1000, 0), 8000, 3, '{}', 10) where catador_id = public._c(1)), 'busca: X marcado em_rota = true');
select ok(not (select em_rota from public.buscar_catadores_proximos(public._lat(1000, 0), public._lng(1000, 0), 8000, 3, '{}', 10) where catador_id = public._c(2)), 'busca: D (disponivel) com em_rota = false');
select ok((select abs(distancia_m - 1000) < 1 from public.buscar_catadores_proximos(public._lat(1000, 0), public._lng(1000, 0), 8000, 3, '{}', 10) where catador_id = public._c(1)), 'busca: distancia_m = distancia do catador a nova coleta');
select is(public._busca(1000, 90, 3), array[public._c(2), public._c(1)], 'busca N2 (desvio ~1162 m, dentro): disponivel sem desvio tem preferencia sobre X');
select is(public._busca(2000, 90, 3), array[public._c(2)], 'busca N3 (desvio ~2606 m > 1500 m): X fora');
select is(public._busca(1000, 0, 8), array[public._c(1), public._c(2)], 'capacidade: 2 sacos na rota + 8 = 10, cabe');
select is(public._busca(1000, 0, 9), array[public._c(2)], 'capacidade: 2 + 9 > 10, X fora (nunca recebe oferta que estoura)');
select is(public._busca(1000, 0, 3, 500), '{}'::uuid[], 'raio de 500 m: ninguem (X a 1000 m)');
select is(public._busca(1000, 0, 3, 8000, array[public._c(1)]), array[public._c(2)], 'p_excluir vale para X em rota');

update parametros set valor = '500'::jsonb where chave = 'desvio_max_rota_m';
select is(public._busca(1000, 90, 3), array[public._c(2)], 'parametro desvio_max_rota_m = 500: N2 deixa de atender');
update parametros set valor = '1500'::jsonb where chave = 'desvio_max_rota_m';
select is(public._busca(1000, 90, 3), array[public._c(2), public._c(1)], 'parametro restaurado: N2 volta a atender');

update rotas set status = 'planejada' where id = '00000000-0000-0000-0000-0000000000c0';
select is(public._busca(1000, 0, 3), array[public._c(2)], 'rota so planejada (nao em_andamento): X fora');
update rotas set status = 'em_andamento' where id = '00000000-0000-0000-0000-0000000000c0';
update rota_paradas set status = 'no_local' where id = '00000000-0000-0000-0000-0000000000d1';
select is(public._busca(1000, 0, 3), array[public._c(2)], 'catador parado em um local (no_local): X fora');
update rota_paradas set status = 'a_caminho' where id = '00000000-0000-0000-0000-0000000000d1';
update catadores set status_cadastro = 'pendente' where perfil_id = public._c(1);
select is(public._busca(1000, 0, 3), array[public._c(2)], 'RN10: X nao aprovado fora');
update catadores set status_cadastro = 'aprovado' where perfil_id = public._c(1);
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, status, pin_coleta)
values ('00000000-0000-0000-0000-0000000000a9', public._g(5), public._pt(500, 180), 1, 'buscando', '9999');
insert into ofertas (id, solicitacao_id, catador_id, ordem, expira_em)
values ('00000000-0000-0000-0000-0000000000f9', '00000000-0000-0000-0000-0000000000a9', public._c(1), 1, now() + interval '1 minute');
select is(public._busca(1000, 0, 3), array[public._c(2)], 'X com oferta pendente de outra solicitacao: fora');
delete from ofertas where id = '00000000-0000-0000-0000-0000000000f9';
delete from solicitacoes where id = '00000000-0000-0000-0000-0000000000a9';
select is(public._busca(1000, 0, 3), array[public._c(1), public._c(2)], 'estado restaurado: X e D de volta');
select ok(not has_function_privilege('authenticated', 'public.buscar_catadores_proximos(float8,float8,int,int,uuid[],int)', 'execute'), 'busca segue interna (nao vaza posicoes)');

-- ---------- aceite de oferta extra: insere a parada na rota unica ----------
select public._as(public._g(2));
select set_config('t.s1', public.criar_solicitacao(public._lat(1000, 0), public._lng(1000, 0), 'Rua N1', 3)::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.s1')::uuid)), public._c(1), 'oferta extra vai ao X em rota (dentro do raio 3 km)');
select ok((select na_rota and ordem = 1 and distancia_m between 999 and 1001 from ofertas where id = public._pendente(current_setting('t.s1')::uuid)), 'oferta marcada na_rota = true, distancia ao catador');
select set_config('t.o1', public._pendente(current_setting('t.s1')::uuid)::text, true);

select public._as(public._c(2));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.o1')), 'P0001', 'oferta_inexistente', 'catador errado nao aceita oferta extra alheia');
reset role; select public._as(public._g(2));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.o1')), 'P0001', 'sem_permissao', 'gerador nao aceita oferta');
reset role;
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'buscando', 'tentativas erradas nao alteram a solicitacao');
select is((select count(*)::int from rota_paradas where rota_id = '00000000-0000-0000-0000-0000000000c0'), 2, 'tentativas erradas nao inserem parada');

select public._as(public._c(1));
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'catador em rota nao le pin_coleta');
select set_config('t.r1', public.aceitar_oferta(current_setting('t.o1')::uuid)::text, true);
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'apos aceitar extra, catador segue sem ler pin_coleta');
reset role;
select is(current_setting('t.r1')::uuid, '00000000-0000-0000-0000-0000000000c0'::uuid, 'aceite devolve a rota existente');
select is((select count(*)::int from rotas where catador_id = public._c(1) and status in ('planejada','em_andamento')), 1, 'rota unica por catador (nenhuma segunda rota aberta)');
select is((select count(*)::int from rotas where catador_id = public._c(1)), 1, 'nenhuma rota nova criada');
select is((select status::text from rotas where id = current_setting('t.r1')::uuid), 'em_andamento', 'rota segue em_andamento');
select is((select versao from rotas where id = current_setting('t.r1')::uuid), 2, 'rota marcada para replanejar (versao + 1)');
select is((select situacao::text from catadores where perfil_id = public._c(1)), 'em_rota', 'catador segue em_rota');
select is((select status::text from ofertas where id = current_setting('t.o1')::uuid), 'aceita', 'oferta aceita');
select is((select status::text from solicitacoes where id = current_setting('t.s1')::uuid), 'aceita', 'solicitacao aceita');
select is((select catador_id from solicitacoes where id = current_setting('t.s1')::uuid), public._c(1), 'catador atribuido');
select is((select ordem from rota_paradas where rota_id = current_setting('t.r1')::uuid and solicitacao_id = current_setting('t.s1')::uuid), 3, 'parada de coleta inserida na rota (apos as existentes)');
select is((select status::text from rota_paradas where id = '00000000-0000-0000-0000-0000000000d1'), 'a_caminho', 'parada em curso intocada');
select is((select status::text from rota_paradas where rota_id = current_setting('t.r1')::uuid and solicitacao_id = current_setting('t.s1')::uuid), 'pendente', 'nova parada pendente (ha coleta em curso)');
select is((select count(*)::int from notificacoes where perfil_id = public._g(2) and tipo = 'oferta_aceita'), 1, 'gerador notificado do aceite');

-- ---------- sem capacidade: nao e ofertada nem aceita ----------
select public._as(public._g(3));
select set_config('t.s2', public.criar_solicitacao(public._lat(1000, 90), public._lng(1000, 90), 'Rua N2', 6)::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.s2')::uuid)), public._c(2), '6 sacos (X tem 5 de folga): oferta vai ao disponivel D');
select ok(not (select na_rota from ofertas where id = public._pendente(current_setting('t.s2')::uuid)), 'oferta normal a D: na_rota = false');

select public._as(public._g(4));
select set_config('t.s3', public.criar_solicitacao(public._lat(1000, 0), public._lng(1000, 0), 'Rua N1b', 3)::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.s3')::uuid)), public._c(1), '3 sacos cabem: nova oferta extra ao X');
select set_config('t.o3', public._pendente(current_setting('t.s3')::uuid)::text, true);
update catadores set capacidade_sacos = 7 where perfil_id = public._c(1);
select public._as(public._c(1));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.o3')), 'P0001', 'sem_capacidade', 'aceite que estoura a capacidade falha (RN04)');
reset role;
update catadores set capacidade_sacos = 10 where perfil_id = public._c(1);
select is((select count(*)::int from rota_paradas where rota_id = current_setting('t.r1')::uuid), 3, 'sem_capacidade nao insere parada');
select is((select versao from rotas where id = current_setting('t.r1')::uuid), 2, 'sem_capacidade nao altera a versao da rota');

update rotas set status = 'planejada' where id = current_setting('t.r1')::uuid;
select public._as(public._c(1));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.o3')), 'P0001', 'catador_indisponivel', 'oferta extra com rota nao iniciada (planejada): indisponivel');
reset role;
update rotas set status = 'em_andamento' where id = current_setting('t.r1')::uuid;
update ofertas set na_rota = false where id = current_setting('t.o3')::uuid;
select public._as(public._c(1));
select throws_ok(format($$select public.aceitar_oferta(%L)$$, current_setting('t.o3')), 'P0001', 'catador_indisponivel', 'oferta normal (nao na_rota) a catador em_rota segue indisponivel');
reset role;
update ofertas set status = 'recusada' where id = current_setting('t.o3')::uuid;   -- libera X para o proximo cenario

-- ---------- rota ja iniciada com paradas concluidas; catador indo ao descarte ----------
update rota_paradas set status = 'concluida', concluida_em = now() where id = '00000000-0000-0000-0000-0000000000d1';
update rota_paradas set status = 'concluida', concluida_em = now()
 where rota_id = current_setting('t.r1')::uuid and solicitacao_id = current_setting('t.s1')::uuid;
update solicitacoes set status = 'coletada' where id in ('00000000-0000-0000-0000-0000000000a0', current_setting('t.s1')::uuid);
select public._as(public._g(5));
select set_config('t.s4', public.criar_solicitacao(public._lat(1000, 0), public._lng(1000, 0), 'Rua N1c', 3)::text, true);
reset role;
select is((select catador_id from ofertas where id = public._pendente(current_setting('t.s4')::uuid)), public._c(1), 'proxima parada = descarte (6 km ao norte): X ainda recebe oferta no caminho');
select public._as(public._c(1));
select is(public.aceitar_oferta(public._pendente(current_setting('t.s4')::uuid)), current_setting('t.r1')::uuid, 'aceite com paradas concluidas devolve a mesma rota');
reset role;
select is((select count(*)::int from rotas where catador_id = public._c(1)), 1, 'segue uma unica rota');
select is((select versao from rotas where id = current_setting('t.r1')::uuid), 3, 'versao + 1 de novo');
select is((select ordem from rota_paradas where rota_id = current_setting('t.r1')::uuid and solicitacao_id = current_setting('t.s4')::uuid), 4, 'nova parada depois das concluidas');
select is((select status::text from rota_paradas where rota_id = current_setting('t.r1')::uuid and solicitacao_id = current_setting('t.s4')::uuid), 'a_caminho', 'sem coleta em curso: nova parada promovida a a_caminho');
select is((select status::text from solicitacoes where id = current_setting('t.s4')::uuid), 'a_caminho', 'solicitacao a_caminho');
select is((select count(*)::int from notificacoes where perfil_id = public._g(5) and tipo = 'catador_a_caminho'), 1, 'gerador recebe aviso de catador a caminho');
select is((select count(*)::int from rota_paradas where rota_id = current_setting('t.r1')::uuid and status = 'concluida'), 2, 'paradas concluidas intactas');

-- X sem mais paradas abertas alem do descarte e da nova coleta; capacidade cheia nao atende
-- carga 2+3+3 = 8 de 10; D tem oferta pendente (s2) e fica fora da busca
select is(public._busca(1000, 0, 3), '{}'::uuid[], 'folga de 2 sacos: 3 sacos nao cabem, X fora');
select is(public._busca(1000, 0, 2), array[public._c(1)], 'folga de 2 sacos: 2 sacos cabem, X atende');

select * from finish();
rollback;
