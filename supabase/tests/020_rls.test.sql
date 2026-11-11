-- T1.2: RLS, grants por coluna, views seguras e helpers. Usuarios simulados com
-- set local role + request.jwt.claims. Fixtures criadas como postgres dentro da transacao.
begin;
select plan(146);

-- ---------- estrutura (como postgres) ----------
select is(
  (select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
      and c.relkind in ('r','p') and not c.relrowsecurity),
  0, 'nenhuma tabela do schema public com RLS desligado');

-- pin e dados sensiveis fora do SELECT do authenticated e do anon
select ok(not has_column_privilege('authenticated', 'public.solicitacoes', 'pin_coleta', 'select'), 'authenticated sem SELECT em solicitacoes.pin_coleta');
select ok(not has_column_privilege('authenticated', 'public.solicitacoes', 'pin_erros', 'select'), 'authenticated sem SELECT em solicitacoes.pin_erros');
select ok(not has_column_privilege('authenticated', 'public.solicitacoes', 'bloqueio_pin_ate', 'select'), 'authenticated sem SELECT em solicitacoes.bloqueio_pin_ate');
select ok(not has_column_privilege('anon', 'public.solicitacoes', 'pin_coleta', 'select'), 'anon sem SELECT em solicitacoes.pin_coleta');
select ok(not has_column_privilege('authenticated', 'public.solicitacoes', 'pin_coleta', 'update'), 'authenticated sem UPDATE em pin_coleta');
select ok(not has_column_privilege('authenticated', 'public.solicitacoes', 'pin_coleta', 'insert'), 'authenticated sem INSERT em pin_coleta');
select ok(has_column_privilege('authenticated', 'public.solicitacoes', 'status', 'select'), 'authenticated le solicitacoes.status (colunas nao sensiveis)');
select ok(not has_column_privilege('authenticated', 'public.catadores', 'documento', 'select'), 'authenticated sem SELECT em catadores.documento');
select ok(not has_column_privilege('authenticated', 'public.catadores', 'razao_social', 'select'), 'authenticated sem SELECT em catadores.razao_social');
select ok(has_column_privilege('authenticated', 'public.catadores', 'situacao', 'select'), 'authenticated le catadores.situacao');
select ok(not has_column_privilege('authenticated', 'public.catadores', 'situacao', 'update'), 'situacao do catador so por RPC');
select ok(not has_column_privilege('authenticated', 'public.catadores', 'localizacao_atual', 'update'), 'posicao do catador so por RPC');
select ok(not has_column_privilege('authenticated', 'public.perfis', 'papel', 'update'), 'papel de perfis nao e atualizavel');
select ok(not has_column_privilege('authenticated', 'public.rotas', 'polyline', 'select'), 'authenticated sem SELECT em rotas.polyline');
select is(
  (select count(*)::int from information_schema.role_column_grants where table_schema = 'public' and grantee = 'anon'),
  0, 'anon sem grant de coluna em public');
select ok(not has_table_privilege('anon', 'public.v_oferta_resumo', 'select'), 'anon sem acesso a v_oferta_resumo');
select ok(not has_table_privilege('anon', 'public.v_solicitacao_gerador', 'select'), 'anon sem acesso a v_solicitacao_gerador');
select ok(has_table_privilege('authenticated', 'public.v_solicitacao_catador', 'select'), 'authenticated acessa v_solicitacao_catador');

-- views: colunas
select hasnt_column('public', 'v_oferta_resumo', 'pin_coleta', 'v_oferta_resumo sem pin');
select hasnt_column('public', 'v_oferta_resumo', 'endereco_texto', 'v_oferta_resumo sem endereco_texto');
select hasnt_column('public', 'v_oferta_resumo', 'lat', 'v_oferta_resumo sem lat exata');
select hasnt_column('public', 'v_oferta_resumo', 'observacao', 'v_oferta_resumo sem observacao');
select hasnt_column('public', 'v_solicitacao_catador', 'pin_coleta', 'v_solicitacao_catador sem pin');
select hasnt_column('public', 'v_solicitacao_catador', 'pin_erros', 'v_solicitacao_catador sem pin_erros');
select has_column('public', 'v_solicitacao_gerador', 'pin_coleta', 'v_solicitacao_gerador tem o pin (so o dono)');
select hasnt_column('public', 'v_solicitacao_catador', 'telefone', 'v_solicitacao_catador sem telefone do gerador');
select hasnt_column('public', 'v_solicitacao_gerador', 'telefone', 'v_solicitacao_gerador sem telefone do catador');

-- funcoes: execute explicito e search_path
select ok(has_function_privilege('authenticated', 'public.papel_atual()', 'execute'), 'authenticated executa papel_atual()');
select ok(not has_function_privilege('anon', 'public.papel_atual()', 'execute'), 'anon nao executa papel_atual()');
select ok(not has_function_privilege('authenticated', 'public.tg_catador_protege_status()', 'execute'), 'funcao de trigger nao executavel por authenticated');
select is(
  (select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
      and not coalesce(p.proconfig::text, '') like '%search_path=%'),
  0, 'toda funcao security definer de public tem search_path explicito');

-- ---------- fixtures ----------
insert into auth.users (id) select ('00000000-0000-0000-0000-' || lpad(x, 12, '0'))::uuid
from unnest(array['a001','a002','a003','c001','c002','c003','b001','b002','ad00','f001']) as x;
insert into perfis (id, papel, nome, telefone) values
  ('00000000-0000-0000-0000-00000000a001', 'gerador', 'Ger 1', '11-1111'),
  ('00000000-0000-0000-0000-00000000a002', 'gerador', 'Ger 2', '11-2222'),
  ('00000000-0000-0000-0000-00000000a003', 'gerador', 'Ger 3', '11-3333'),
  ('00000000-0000-0000-0000-00000000c001', 'catador', 'Cat 1', '11-9001'),
  ('00000000-0000-0000-0000-00000000c002', 'catador', 'Cat 2', '11-9002'),
  ('00000000-0000-0000-0000-00000000c003', 'catador', 'Cat 3', '11-9003'),
  ('00000000-0000-0000-0000-00000000b001', 'ponto',   'Op 1', null),
  ('00000000-0000-0000-0000-00000000b002', 'ponto',   'Op 2', null),
  ('00000000-0000-0000-0000-00000000ad00', 'admin',   'Admin', null);
insert into geradores (perfil_id) values
  ('00000000-0000-0000-0000-00000000a001'), ('00000000-0000-0000-0000-00000000a002'), ('00000000-0000-0000-0000-00000000a003');
insert into catadores (perfil_id, documento, razao_social, status_cadastro, tipo_veiculo, localizacao_atual) values
  ('00000000-0000-0000-0000-00000000c001', 'DOC-C1', 'Razao C1', 'aprovado', 'carrinho', 'SRID=4326;POINT(-46.64 -23.56)'::geography),
  ('00000000-0000-0000-0000-00000000c002', 'DOC-C2', 'Razao C2', 'aprovado', 'moto',     'SRID=4326;POINT(-46.65 -23.57)'::geography),
  ('00000000-0000-0000-0000-00000000c003', 'DOC-C3', null,       'pendente', 'bicicleta', null);
insert into materiais (id, codigo, nome, categoria) values (1, 'papel', 'Papel', 'papel'), (2, 'pet', 'PET', 'plastico');
insert into pontos_coleta (id, perfil_id, nome, logradouro, cidade, uf, localizacao) values
  ('00000000-0000-0000-0000-000000007001', '00000000-0000-0000-0000-00000000b001', 'Ponto 1', 'Rua A', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.63 -23.55)'::geography),
  ('00000000-0000-0000-0000-000000007002', '00000000-0000-0000-0000-00000000b002', 'Ponto 2', 'Rua B', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.62 -23.54)'::geography);
insert into enderecos (id, perfil_id, logradouro, bairro, cidade, uf, localizacao) values
  ('00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000a001', 'Rua do G1', 'Centro', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.63 -23.55)'::geography),
  ('00000000-0000-0000-0000-00000000e002', '00000000-0000-0000-0000-00000000a002', 'Rua do G2', 'Vila Nova', 'Sao Paulo', 'SP', 'SRID=4326;POINT(-46.6334 -23.5512)'::geography);
insert into solicitacoes (id, gerador_id, endereco_id, localizacao, endereco_texto, qtd_sacos, tamanho, observacao, status, pin_coleta, catador_id) values
  ('00000000-0000-0000-0000-000000005001', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000e001',
   'SRID=4326;POINT(-46.63 -23.55)'::geography, 'Rua do G1, 10', 2, 'M', 'portao azul', 'aceita', '1111', '00000000-0000-0000-0000-00000000c001'),
  ('00000000-0000-0000-0000-000000005002', '00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000e002',
   'SRID=4326;POINT(-46.6334 -23.5512)'::geography, 'Rua Secreta 99', 3, 'G', 'casa verde', 'buscando', '2222', null),
  ('00000000-0000-0000-0000-000000005003', '00000000-0000-0000-0000-00000000a003', null,
   'SRID=4326;POINT(-46.61 -23.53)'::geography, 'Rua do G3, 30', 1, 'P', null, 'aceita', '3333', '00000000-0000-0000-0000-00000000c001');
insert into solicitacao_materiais values
  ('00000000-0000-0000-0000-000000005001', 1), ('00000000-0000-0000-0000-000000005002', 1), ('00000000-0000-0000-0000-000000005002', 2);
insert into ofertas (id, solicitacao_id, catador_id, ordem, status, expira_em) values
  ('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-000000005001', '00000000-0000-0000-0000-00000000c001', 1, 'aceita', now()),
  ('00000000-0000-0000-0000-00000000f002', '00000000-0000-0000-0000-000000005002', '00000000-0000-0000-0000-00000000c001', 1, 'recusada', now()),
  ('00000000-0000-0000-0000-00000000f003', '00000000-0000-0000-0000-000000005002', '00000000-0000-0000-0000-00000000c002', 2, 'pendente', now() + interval '45 seconds');
insert into rotas (id, catador_id, ponto_destino_id, polyline) values
  ('00000000-0000-0000-0000-000000008001', '00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-000000007001', 'SECRETPOLY');
insert into rota_paradas (id, rota_id, ordem, tipo, solicitacao_id, ponto_id, localizacao) values
  ('00000000-0000-0000-0000-000000009001', '00000000-0000-0000-0000-000000008001', 1, 'coleta', '00000000-0000-0000-0000-000000005001', null, 'SRID=4326;POINT(-46.63 -23.55)'::geography),
  ('00000000-0000-0000-0000-000000009003', '00000000-0000-0000-0000-000000008001', 2, 'coleta', '00000000-0000-0000-0000-000000005003', null, 'SRID=4326;POINT(-46.61 -23.53)'::geography),
  ('00000000-0000-0000-0000-000000009009', '00000000-0000-0000-0000-000000008001', 3, 'descarte', null, '00000000-0000-0000-0000-000000007001', 'SRID=4326;POINT(-46.63 -23.55)'::geography);
insert into entregas (id, rota_id, ponto_id, catador_id) values
  ('00000000-0000-0000-0000-00000000e0e1', '00000000-0000-0000-0000-000000008001', '00000000-0000-0000-0000-000000007001', '00000000-0000-0000-0000-00000000c001');
insert into entrega_itens (entrega_id, material_id, peso_kg, preco_kg, valor) values
  ('00000000-0000-0000-0000-00000000e0e1', 1, 10, 1, 10);
insert into avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota) values
  ('00000000-0000-0000-0000-000000005001', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000c001', 5);
insert into notificacoes (id, perfil_id, tipo, titulo) values
  ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000a001', 't', 'N G1'),
  ('00000000-0000-0000-0000-00000000d002', '00000000-0000-0000-0000-00000000a002', 't', 'N G2');
insert into localizacoes_catador (catador_id, localizacao) values
  ('00000000-0000-0000-0000-00000000c001', 'SRID=4326;POINT(-46.64 -23.56)'::geography);

-- helpers de teste: trocar de usuario e contar linhas afetadas por um comando
create function public._as(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;
create function public._rows(p_sql text) returns int language plpgsql as $$
declare n int;
begin execute p_sql; get diagnostics n = row_count; return n; end $$;
grant execute on function public._rows(text) to authenticated, anon;

-- ================= GERADOR 1 (dono da S1, atendida por C1) =================
select public._as('00000000-0000-0000-0000-00000000a001');
select is((select public.papel_atual()::text), 'gerador', 'papel_atual() = gerador');
select is((select count(*)::int from solicitacoes), 1, 'G1 ve so a propria solicitacao');
select is((select count(*)::int from solicitacoes where id = '00000000-0000-0000-0000-000000005002'), 0, 'G1 nao le a solicitacao do G2 (RLS)');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'G1 nao le pin_coleta direto na tabela');
select throws_ok($$select * from solicitacoes$$, '42501', null, 'select * em solicitacoes falha (colunas protegidas)');
select is((select pin_coleta::text from v_solicitacao_gerador), '1111', 'G1 le o proprio PIN pela view do gerador');
select is((select count(*)::int from v_solicitacao_gerador where id = '00000000-0000-0000-0000-000000005002'), 0, 'view do gerador nao devolve solicitacao do G2');
select is((select catador_nome from v_solicitacao_gerador), 'Cat 1', 'G1 ve o nome do catador que atende');
select ok((select catador_lat is not null from v_solicitacao_gerador), 'G1 ve a posicao do catador durante a coleta ativa');
select throws_ok($$update solicitacoes set status = 'cancelada'$$, '42501', null, 'G1 nao atualiza solicitacoes direto (RPC)');
select throws_ok($$update solicitacoes set pin_coleta = '0000'$$, '42501', null, 'G1 nao altera o proprio PIN');
select throws_ok($$delete from solicitacoes$$, '42501', null, 'G1 nao apaga solicitacoes');
select throws_ok($$insert into solicitacoes (gerador_id, localizacao, qtd_sacos, pin_coleta)
  values ('00000000-0000-0000-0000-00000000a001', 'SRID=4326;POINT(-46.63 -23.55)'::geography, 1, '9999')$$,
  '42501', null, 'G1 nao insere solicitacao direto (RPC)');
select is((select count(*)::int from enderecos), 1, 'G1 ve so o proprio endereco');
select is(public._rows($$update enderecos set cidade = 'X' where id = '00000000-0000-0000-0000-00000000e002'$$), 0, 'G1 nao altera endereco do G2');
select is(public._rows($$delete from enderecos where id = '00000000-0000-0000-0000-00000000e002'$$), 0, 'G1 nao apaga endereco do G2');
select throws_ok($$insert into enderecos (perfil_id, logradouro, cidade, uf, localizacao)
  values ('00000000-0000-0000-0000-00000000a002', 'x', 'y', 'SP', 'SRID=4326;POINT(0 0)'::geography)$$,
  '42501', null, 'G1 nao cria endereco em nome do G2');
select throws_ok($$update geradores set endereco_padrao_id = '00000000-0000-0000-0000-00000000e002'
  where perfil_id = '00000000-0000-0000-0000-00000000a001'$$, '23503', null, 'G1 nao usa endereco do G2 como padrao (IDOR)');
select is((select count(*)::int from perfis), 1, 'G1 so ve o proprio perfil (sem telefone alheio)');
select is((select count(*)::int from catadores), 0, 'G1 nao le catadores direto (usa a view)');
select throws_ok($$update perfis set papel = 'admin'$$, '42501', null, 'G1 nao muda o proprio papel');
select is(public._rows($$update perfis set nome = 'Ger Um' where id = '00000000-0000-0000-0000-00000000a001'$$), 1, 'G1 edita o proprio nome');
select is(public._rows($$update perfis set nome = 'hack' where id = '00000000-0000-0000-0000-00000000a002'$$), 0, 'G1 nao edita perfil alheio');
select is((select count(*)::int from ofertas), 0, 'G1 nao le ofertas');
select is((select count(*)::int from rotas), 1, 'G1 ve a rota que atende sua solicitacao');
select throws_ok($$select polyline from rotas$$, '42501', null, 'G1 nao le a polyline da rota (paradas de outros)');
select is((select count(*)::int from rota_paradas), 1, 'G1 ve so a parada da propria solicitacao');
select is((select count(*)::int from entregas), 0, 'G1 nao le entregas');
select is((select count(*)::int from avaliacoes), 1, 'G1 ve a avaliacao que fez');
select is((select count(*)::int from localizacoes_catador), 1, 'G1 ve o rastro do catador que o atende');
select is((select count(*)::int from notificacoes), 1, 'G1 ve so as proprias notificacoes');
select is(public._rows($$update notificacoes set lida = true where id = '00000000-0000-0000-0000-00000000d001'$$), 1, 'G1 marca a propria notificacao como lida');
select is(public._rows($$update notificacoes set lida = true where id = '00000000-0000-0000-0000-00000000d002'$$), 0, 'G1 nao marca notificacao do G2');
select throws_ok($$update notificacoes set titulo = 'x'$$, '42501', null, 'G1 so altera notificacoes.lida');
select is((select count(*)::int from v_oferta_resumo), 0, 'G1 nao tem ofertas');
select ok((select count(*)::int from parametros) > 0, 'G1 le parametros');
select is(public._rows($$update parametros set valor = '1'::jsonb where chave = 'pin_max_erros'$$), 0, 'G1 nao altera parametros');
select throws_ok($$insert into materiais (id, codigo, nome, categoria) values (9, 'x', 'X', 'x')$$, '42501', null, 'G1 nao cria materiais');
select throws_ok($$insert into ponto_precos (ponto_id, material_id, preco_kg) values ('00000000-0000-0000-0000-000000007001', 2, 1)$$,
  '42501', null, 'G1 nao cadastra preco em ponto');

-- ================= CATADOR 2 (so oferta pendente da S2) =================
reset role;
select public._as('00000000-0000-0000-0000-00000000c002');
select is((select count(*)::int from solicitacoes), 0, 'C2 (oferta pendente) nao le solicitacoes: sem endereco exato');
select is((select count(*)::int from solicitacoes where id = '00000000-0000-0000-0000-000000005002'), 0, 'C2 nao le endereco_texto da S2 antes do aceite');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'C2 nao le pin_coleta');
select is((select count(*)::int from v_oferta_resumo), 1, 'C2 ve a oferta pendente no resumo');
select is((select qtd_sacos from v_oferta_resumo), 3, 'resumo mostra qtd_sacos');
select is((select materiais from v_oferta_resumo), array[1,2]::smallint[], 'resumo mostra materiais');
select is((select bairro from v_oferta_resumo), 'Vila Nova', 'resumo mostra bairro');
select is((select aprox_lat from v_oferta_resumo)::numeric, -23.55, 'resumo traz localizacao aproximada (grade ~1 km), nao a exata');
select ok((select aprox_lng <> -46.6334 from v_oferta_resumo), 'aprox_lng difere da longitude exata');
select is((select count(*)::int from v_solicitacao_catador), 0, 'C2 nao tem solicitacao atribuida');
select is((select count(*)::int from ofertas), 1, 'C2 ve so a propria oferta');
select throws_ok($$update ofertas set status = 'aceita'$$, '42501', null, 'C2 nao aceita oferta direto (RPC)');
select is((select count(*)::int from rotas), 0, 'C2 nao ve rota alheia');
select is((select count(*)::int from rota_paradas), 0, 'C2 nao ve paradas alheias');
select is((select count(*)::int from v_rota_catador), 0, 'C2 nao ve v_rota_catador alheia');
select is((select count(*)::int from catadores), 1, 'C2 ve so a propria linha em catadores');
select throws_ok($$select documento from catadores$$, '42501', null, 'C2 nao le documento direto');
select is((select documento from v_catador_privado), 'DOC-C2', 'C2 le o proprio documento pela view privada');
select is((select count(*)::int from v_catador_privado), 1, 'view privada devolve so a propria linha');
select is((select count(*)::int from perfis), 1, 'C2 nao le perfil do gerador');
select throws_ok($$update catadores set status_cadastro = 'suspenso' where perfil_id = '00000000-0000-0000-0000-00000000c002'$$,
  'P0001', 'status_cadastro: somente admin', 'C2 nao altera o proprio status_cadastro');
select throws_ok($$update catadores set situacao = 'disponivel'$$, '42501', null, 'C2 nao altera situacao direto');
select throws_ok($$update catadores set localizacao_atual = 'SRID=4326;POINT(0 0)'::geography$$, '42501', null, 'C2 nao altera posicao direto');
select throws_ok($$update catadores set avaliacao_media = 5$$, '42501', null, 'C2 nao altera a propria nota');
select is(public._rows($$update catadores set tipo_veiculo = 'moto 2' where perfil_id = '00000000-0000-0000-0000-00000000c002'$$), 1, 'C2 edita o proprio veiculo');
select is(public._rows($$update catadores set tipo_veiculo = 'hack' where perfil_id = '00000000-0000-0000-0000-00000000c001'$$), 0, 'C2 nao edita catador alheio');
select is((select count(*)::int from localizacoes_catador), 0, 'C2 nao ve rastro de outro catador');
select is((select count(*)::int from avaliacoes), 0, 'C2 nao ve avaliacoes alheias');

-- ================= CATADOR 1 (atribuido a S1 e S3) =================
reset role;
select public._as('00000000-0000-0000-0000-00000000c001');
select is((select count(*)::int from solicitacoes), 2, 'C1 le as solicitacoes atribuidas (apos aceite)');
select is((select count(*)::int from solicitacoes where id = '00000000-0000-0000-0000-000000005002'), 0, 'C1 nao le S2 (oferta recusada)');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'C1 nao le pin_coleta (tabela)');
select throws_ok($$select pin_coleta from v_solicitacao_catador$$, '42703', null, 'v_solicitacao_catador nao tem pin_coleta');
select is((select count(*)::int from v_solicitacao_catador), 2, 'v_solicitacao_catador devolve as 2 atribuidas');
select is((select endereco_texto from v_solicitacao_catador where id = '00000000-0000-0000-0000-000000005001'), 'Rua do G1, 10', 'C1 ve endereco exato apos aceite');
select is((select gerador_nome from v_solicitacao_catador where id = '00000000-0000-0000-0000-000000005001'), 'Ger Um', 'C1 ve nome do gerador, nao o telefone');
select is((select count(*)::int from v_oferta_resumo), 0, 'oferta recusada/aceita nao aparece no resumo');
select is((select polyline from v_rota_catador), 'SECRETPOLY', 'C1 le a polyline pela view da rota');
select is((select count(*)::int from rota_paradas), 3, 'C1 ve todas as paradas da propria rota');
select is((select count(*)::int from entregas), 1, 'C1 ve a propria entrega');
select is((select count(*)::int from entrega_itens), 1, 'C1 ve os itens da propria entrega');
select is((select count(*)::int from perfis), 1, 'C1 nao le perfis alheios');

-- ================= CATADOR 3 (pendente) =================
reset role;
select public._as('00000000-0000-0000-0000-00000000c003');
select is((select status_cadastro::text from catadores), 'pendente', 'C3 pendente ve o proprio status');
select throws_ok($$update catadores set status_cadastro = 'aprovado'$$, 'P0001', 'status_cadastro: somente admin', 'catador pendente nao se auto-aprova');
select is((select count(*)::int from v_oferta_resumo), 0, 'C3 sem ofertas');
select throws_ok($$insert into ofertas (solicitacao_id, catador_id, ordem, expira_em)
  values ('00000000-0000-0000-0000-000000005002', '00000000-0000-0000-0000-00000000c003', 9, now())$$, '42501', null, 'C3 nao cria oferta para si');

-- ================= PONTO 1 =================
reset role;
select public._as('00000000-0000-0000-0000-00000000b001');
select is(public._rows($$update pontos_coleta set nome = 'Ponto 1b' where id = '00000000-0000-0000-0000-000000007001'$$), 1, 'operador edita o proprio ponto');
select is(public._rows($$update pontos_coleta set nome = 'hack' where id = '00000000-0000-0000-0000-000000007002'$$), 0, 'operador nao edita outro ponto');
select lives_ok($$insert into ponto_precos (ponto_id, material_id, preco_kg) values ('00000000-0000-0000-0000-000000007001', 1, 1.5)$$, 'operador cadastra preco no proprio ponto');
select throws_ok($$insert into ponto_precos (ponto_id, material_id, preco_kg) values ('00000000-0000-0000-0000-000000007002', 1, 9)$$, '42501', null, 'operador nao cadastra preco em outro ponto');
select is((select count(*)::int from entregas), 1, 'operador ve entrega do seu ponto');
select is((select count(*)::int from rotas), 1, 'operador ve a rota com destino no seu ponto');
select is((select count(*)::int from rota_paradas), 1, 'operador ve so a parada de descarte do seu ponto');
select is((select count(*)::int from solicitacoes), 0, 'operador nao le solicitacoes');
select throws_ok($$insert into pontos_coleta (nome, logradouro, cidade, uf, localizacao)
  values ('novo', 'x', 'y', 'SP', 'SRID=4326;POINT(0 0)'::geography)$$, '42501', null, 'operador nao cria ponto');

-- ================= PONTO 2 (outro ponto) =================
reset role;
select public._as('00000000-0000-0000-0000-00000000b002');
select is((select count(*)::int from entregas), 0, 'outro operador nao ve entregas');
select is((select count(*)::int from rotas), 0, 'outro operador nao ve rotas');

-- ================= ADMIN =================
reset role;
select public._as('00000000-0000-0000-0000-00000000ad00');
select is((select count(*)::int from solicitacoes), 3, 'admin le todas as solicitacoes');
select throws_ok($$select pin_coleta from solicitacoes$$, '42501', null, 'nem admin le pin_coleta direto');
select is((select count(*)::int from v_catador_privado), 3, 'admin le todos os catadores com documento pela view privada');
select is((select count(*)::int from perfis), 9, 'admin le todos os perfis');
select is(public._rows($$update catadores set status_cadastro = 'aprovado' where perfil_id = '00000000-0000-0000-0000-00000000c003'$$), 1, 'admin aprova catador pendente');
select is(public._rows($$update parametros set valor = '4'::jsonb where chave = 'pin_max_erros'$$), 1, 'admin altera parametros');
select lives_ok($$insert into materiais (id, codigo, nome, categoria) values (9, 'x', 'X', 'x')$$, 'admin cria material');

-- ================= NOVO USUARIO (cadastro) =================
reset role;
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000aa01'), ('00000000-0000-0000-0000-00000000aa02');
select public._as('00000000-0000-0000-0000-00000000aa01');
select throws_ok($$insert into perfis (id, papel, nome) values ('00000000-0000-0000-0000-00000000aa01', 'admin', 'Eu')$$,
  '42501', null, 'cadastro nao aceita papel admin');
select throws_ok($$insert into perfis (id, papel, nome) values ('00000000-0000-0000-0000-00000000aa01', 'ponto', 'Eu')$$,
  '42501', null, 'cadastro nao aceita papel ponto');
select throws_ok($$insert into perfis (id, papel, nome) values ('00000000-0000-0000-0000-00000000aa02', 'gerador', 'Outro')$$,
  '42501', null, 'cadastro nao cria perfil para outro usuario');
select lives_ok($$insert into perfis (id, papel, nome) values ('00000000-0000-0000-0000-00000000aa01', 'catador', 'Novo')$$, 'cadastro como catador');
select lives_ok($$insert into catadores (perfil_id, tipo_veiculo, capacidade_sacos) values ('00000000-0000-0000-0000-00000000aa01', 'carrinho', 8)$$, 'catador cria o proprio registro');
select is((select status_cadastro::text from catadores), 'pendente', 'novo catador nasce pendente');
select throws_ok($$insert into geradores (perfil_id) values ('00000000-0000-0000-0000-00000000aa01')$$, '42501', null, 'catador nao cria registro de gerador');
select throws_ok($$insert into catadores (perfil_id, status_cadastro) values ('00000000-0000-0000-0000-00000000aa01', 'aprovado')$$, '42501', null, 'cadastro nao define status_cadastro');

-- ================= ANON =================
reset role;
set local role anon;
select throws_ok($$select * from perfis$$, '42501', null, 'anon nao le perfis');
select throws_ok($$select * from v_oferta_resumo$$, '42501', null, 'anon nao le v_oferta_resumo');
select throws_ok($$select public.papel_atual()$$, '42501', null, 'anon nao executa papel_atual()');
select throws_ok($$select id from materiais$$, '42501', null, 'anon nao le materiais');

reset role;
select * from finish();
rollback;
