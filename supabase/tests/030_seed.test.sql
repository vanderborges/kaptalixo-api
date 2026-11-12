-- T1.3: contagens do seed de demonstracao e ordenacao por distancia.
begin;
select plan(17);

select is((select count(*)::int from materiais), 7, '7 materiais');
select is((select count(*)::int from pontos_coleta), 4, '4 pontos de coleta');
select is((select count(*)::int from ponto_precos), 28, '28 precos (4 pontos x 7 materiais)');
select is((select count(distinct preco_kg)::int from ponto_precos where material_id = 6), 4, 'aluminio com preco diferente em cada ponto');

select is((select count(*)::int from catadores where status_cadastro = 'aprovado'), 8, '8 catadores aprovados');
select is((select count(*)::int from catadores where status_cadastro = 'aprovado' and tipo = 'pessoa'), 5, '5 pessoas');
select is((select count(*)::int from catadores where status_cadastro = 'aprovado' and tipo = 'empresa'), 3, '3 empresas');
select is((select count(*)::int from catadores where status_cadastro = 'pendente'), 1, '1 catador pendente');
select ok((select min(capacidade_sacos) = 6 and max(capacidade_sacos) = 40 from catadores), 'capacidades de 6 a 40');
select ok((select count(*) filter (where situacao = 'disponivel') > 0 and count(*) filter (where situacao = 'offline') > 0
             from catadores where status_cadastro = 'aprovado'), 'ha catadores disponiveis e offline');

select is((select count(*)::int from geradores g join enderecos e on e.id = g.endereco_padrao_id and e.perfil_id = g.perfil_id), 5, '5 geradores com endereco');
select is((select count(*)::int from perfis where papel = 'admin'), 1, '1 admin');
select is((select count(distinct perfil_id)::int from pontos_coleta p join perfis f on f.id = p.perfil_id and f.papel = 'ponto'), 4, '1 operador por ponto');
select is((select count(*)::int from auth.users u join auth.identities i on i.user_id = u.id), 19, '19 usuarios com identidade no Auth');
select is((select valor from parametros where chave = 'modo_demo'), 'true'::jsonb, 'modo_demo ligado');

-- Ordenacao por distancia: disponiveis num raio de 5 km do endereco do gerador 1.
select ok((select count(*) >= 3 from catadores c, enderecos e
             where e.perfil_id = 'c0000000-0000-4000-8000-000000000001'
               and c.situacao = 'disponivel' and c.status_cadastro = 'aprovado'
               and st_dwithin(c.localizacao_atual, e.localizacao, 5000)), 'ha ao menos 3 catadores disponiveis em 5 km');

select ok((
  with d as (
    select st_distance(c.localizacao_atual, e.localizacao) as dist,
           lag(st_distance(c.localizacao_atual, e.localizacao)) over (order by c.localizacao_atual <-> e.localizacao) as ant
    from catadores c, enderecos e
    where e.perfil_id = 'c0000000-0000-4000-8000-000000000001'
      and c.situacao = 'disponivel' and c.status_cadastro = 'aprovado'
      and st_dwithin(c.localizacao_atual, e.localizacao, 5000)
  )
  select bool_and(ant is null or dist >= ant) from d
), 'catadores proximos saem em ordem crescente de distancia');

select * from finish();
rollback;
