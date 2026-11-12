-- T1.2: completa a cobertura da T1.1 (P-002 item 5) e testa as FKs compostas de endereco (item 3).
begin;
select plan(22);

-- ---------- parametros: as 12 chaves ----------
select results_eq(
  $$select chave from parametros order by chave$$,
  $$values ('custo_km_reais'),('desvio_max_rota_m'),('intervalo_loc_disp_s'),('intervalo_loc_rota_s'),
           ('max_ofertas_por_solicitacao'),('modo_demo'),('oferta_validade_s'),('peso_saco_kg'),
           ('pin_bloqueio_s'),('pin_max_erros'),('raio_chegada_m'),('raios_busca_m')$$,
  'parametros tem exatamente as 12 chaves de docs/05 secao 6');
select is((select valor from parametros where chave = 'oferta_validade_s'), '45'::jsonb, 'oferta_validade_s = 45');
select is((select valor from parametros where chave = 'max_ofertas_por_solicitacao'), '5'::jsonb, 'max_ofertas = 5');
select is((select valor from parametros where chave = 'pin_max_erros'), '3'::jsonb, 'pin_max_erros = 3');

-- ---------- fixtures ----------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000a3'), ('00000000-0000-0000-0000-0000000000a4');
insert into perfis (id, papel, nome) values
  ('00000000-0000-0000-0000-0000000000a1', 'gerador', 'Ger 1'),
  ('00000000-0000-0000-0000-0000000000a2', 'catador', 'Cat 1'),
  ('00000000-0000-0000-0000-0000000000a3', 'catador', 'Cat 2'),
  ('00000000-0000-0000-0000-0000000000a4', 'gerador', 'Ger 2');
insert into geradores (perfil_id) values
  ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000a4');
insert into catadores (perfil_id) values
  ('00000000-0000-0000-0000-0000000000a2'), ('00000000-0000-0000-0000-0000000000a3');
insert into materiais (id, codigo, nome, categoria) values (1, 'papel', 'Papel', 'papel');
insert into pontos_coleta (id, nome, logradouro, cidade, uf, localizacao) values
  ('00000000-0000-0000-0000-0000000000b1', 'Ponto', 'Rua A', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.63 -23.55)'::geography);
insert into solicitacoes (id, gerador_id, localizacao, qtd_sacos, pin_coleta) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1',
   'SRID=4326;POINT(-46.63 -23.55)'::geography, 1, '1234');

-- ---------- ofertas: indice parcial isolado (catadores diferentes) ----------
insert into ofertas (solicitacao_id, catador_id, ordem, expira_em)
values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a2', 1, now() + interval '45 seconds');
select throws_ok($$
  insert into ofertas (solicitacao_id, catador_id, ordem, expira_em)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a3', 2, now() + interval '45 seconds')
$$, '23505', null, 'duas ofertas pendentes para a mesma solicitacao (catadores diferentes) sao rejeitadas');
select lives_ok($$
  insert into ofertas (solicitacao_id, catador_id, ordem, status, expira_em)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a3', 2, 'recusada', now())
$$, 'oferta nao pendente para outro catador e aceita');
update ofertas set status = 'expirada' where catador_id = '00000000-0000-0000-0000-0000000000a2';
select throws_ok($$
  insert into ofertas (solicitacao_id, catador_id, ordem, expira_em)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a4', 3, now())
$$, '23503', null, 'FK de ofertas.catador_id exige catador (a4 e gerador)');

-- ---------- checks ----------
select throws_ok($$update catadores set capacidade_sacos = 0 where perfil_id = '00000000-0000-0000-0000-0000000000a2'$$,
  '23514', null, 'capacidade_sacos = 0 viola check');
select throws_ok($$update catadores set capacidade_sacos = -1 where perfil_id = '00000000-0000-0000-0000-0000000000a2'$$,
  '23514', null, 'capacidade_sacos negativa viola check');
select throws_ok($$insert into ponto_precos (ponto_id, material_id, preco_kg)
  values ('00000000-0000-0000-0000-0000000000b1', 1, -0.01)$$, '23514', null, 'preco_kg negativo viola check');
select lives_ok($$insert into ponto_precos (ponto_id, material_id, preco_kg)
  values ('00000000-0000-0000-0000-0000000000b1', 1, 0)$$, 'preco_kg = 0 e aceito');
select throws_ok($$insert into entrega_itens (entrega_id, material_id, peso_kg, preco_kg, valor)
  values (gen_random_uuid(), 1, 0, 1, 0)$$, '23514', null, 'peso_kg = 0 viola check (antes da FK)');
select lives_ok($$update solicitacoes set qtd_sacos = 20 where id = '00000000-0000-0000-0000-0000000000c1'$$, 'qtd_sacos = 20 aceito');
select lives_ok($$update solicitacoes set qtd_sacos = 1 where id = '00000000-0000-0000-0000-0000000000c1'$$, 'qtd_sacos = 1 aceito');
select throws_ok($$insert into avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 0)$$,
  '23514', null, 'nota 0 viola check');
select lives_ok($$insert into avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 1)$$,
  'nota 1 aceita');
select lives_ok($$insert into avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1', 5)$$,
  'nota 5 aceita');

-- ---------- FK composta de endereco (anti-IDOR) ----------
insert into enderecos (id, perfil_id, logradouro, cidade, uf, localizacao) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1', 'Rua do G1', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.63 -23.55)'::geography),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000a4', 'Rua do G2', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.64 -23.56)'::geography);

select throws_ok($$update geradores set endereco_padrao_id = '00000000-0000-0000-0000-0000000000f4'
  where perfil_id = '00000000-0000-0000-0000-0000000000a1'$$, '23503', null, 'gerador nao aponta endereco_padrao para endereco alheio');
select lives_ok($$update geradores set endereco_padrao_id = '00000000-0000-0000-0000-0000000000f1'
  where perfil_id = '00000000-0000-0000-0000-0000000000a1'$$, 'gerador aponta endereco_padrao para endereco proprio');
select throws_ok($$update solicitacoes set endereco_id = '00000000-0000-0000-0000-0000000000f4'
  where id = '00000000-0000-0000-0000-0000000000c1'$$, '23503', null, 'solicitacao nao referencia endereco de outro gerador');
select lives_ok($$update solicitacoes set endereco_id = '00000000-0000-0000-0000-0000000000f1'
  where id = '00000000-0000-0000-0000-0000000000c1'$$, 'solicitacao referencia endereco do proprio gerador');
select lives_ok($$delete from enderecos where id = '00000000-0000-0000-0000-0000000000f1'$$, 'apagar endereco zera as referencias (set null)');

select * from finish();
rollback;
