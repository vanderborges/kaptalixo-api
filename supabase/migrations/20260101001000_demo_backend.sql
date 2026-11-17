-- T1.6: backend do painel de demonstracao (UC15/UC16) + pontos_proximos + visao do ponto.
-- RPCs demo_*: security definer, search_path explicito, guarda e_admin() + modo_demo, execute so a authenticated.
-- Erros estaveis: sem_permissao, modo_demo_desativado, parametro_invalido, catador_nao_ficticio, sem_gerador_livre.
-- Realtime (ofertas, rotas, rota_paradas, solicitacoes) e grants de v_oferta_resumo/RPCs do ciclo ja existem
-- (migrations 000300, 000600, 000700, 000900); a T1.6 so os cobre com testes (060_demo.test.sql).
set search_path = public, extensions;

-- ---------- atores ficticios (seed e criados pela demo) ----------
-- Sem grants e sem policies: so funcoes definer leem. origem 'seed' = preenchido pelo seed;
-- 'demo' = criado por demo_criar_catadores (removido por resetar_demo).
create table public.demo_atores (
  perfil_id uuid primary key references public.perfis(id) on delete cascade,
  origem    text not null check (origem in ('seed','demo'))
);
alter table public.demo_atores enable row level security;
revoke all on public.demo_atores from public, anon, authenticated;

-- ---------- helpers internos (sem execute para authenticated) ----------
-- Guarda comum das RPCs demo_*: admin autenticado e modo_demo ligado.
create function public._demo_guarda() returns void
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null or not public.e_admin() then
    raise exception 'sem_permissao';
  end if;
  if not coalesce((select (valor #>> '{}')::boolean from public.parametros where chave = 'modo_demo'), false) then
    raise exception 'modo_demo_desativado';
  end if;
end;
$$;

-- Centro da cidade demo: media dos pontos ativos; sem pontos, Sao Paulo.
create function public._demo_centro(out lat float8, out lng float8)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(avg(st_y(p.localizacao::geometry)), -23.5505),
         coalesce(avg(st_x(p.localizacao::geometry)), -46.6333)
    from public.pontos_coleta p where p.ativo
$$;

-- Ponto aberto em p_quando? Mesmo criterio de planejar-rota/escolha_ponto.ts: fuso America/Sao_Paulo,
-- fim exclusivo, intervalo com fim <= inicio vai ate a meia-noite, dado invalido = fechado.
create function public._ponto_aberto(p_horario jsonb, p_quando timestamptz) returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  v_local timestamp := p_quando at time zone 'America/Sao_Paulo';
  v_dia text := (array['dom','seg','ter','qua','qui','sex','sab'])[extract(dow from v_local)::int + 1];
  v_hora time := v_local::time;
  i jsonb;
  v_ini time;
  v_fim time;
begin
  if p_horario is null or jsonb_typeof(p_horario -> v_dia) is distinct from 'array' then
    return false;
  end if;
  for i in select value from jsonb_array_elements(p_horario -> v_dia) loop
    v_ini := (i ->> 0)::time;
    v_fim := (i ->> 1)::time;
    if v_fim <= v_ini then
      if v_hora >= v_ini then
        return true;
      end if;
    elsif v_hora >= v_ini and v_hora < v_fim then
      return true;
    end if;
  end loop;
  return false;
exception when others then
  return false;
end;
$$;

revoke all on function public._demo_guarda(), public._demo_centro(), public._ponto_aberto(jsonb, timestamptz)
  from public, anon, authenticated;

-- ---------- demo_snapshot (ADM, UC15) ----------
-- {"atores":[{id,tipo,nome,lat,lng,situacao}],
--  "rotas":[{id,catador_id,status,polyline,paradas:[{ordem,tipo,status,lat,lng}]}],
--  "eventos":[{id,solicitacao_id,tipo,de_status,para_status,criado_em}]}  (eventos: mais recentes primeiro)
-- Formato lido por SnapshotDemo.fromJson (kaptalixo-web). Nunca inclui pin_coleta.
create function public.demo_snapshot(p_eventos int default 50) returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_atores jsonb;
  v_rotas jsonb;
  v_eventos jsonb;
begin
  perform public._demo_guarda();
  if p_eventos is null or p_eventos not between 1 and 200 then
    raise exception 'parametro_invalido';
  end if;

  select coalesce(jsonb_agg(a.j), '[]'::jsonb) into v_atores from (
    select jsonb_build_object('id', g.perfil_id, 'tipo', 'gerador', 'nome', pg.nome,
             'lat', st_y(e.localizacao::geometry), 'lng', st_x(e.localizacao::geometry), 'situacao', null) as j
      from public.geradores g
      join public.perfis pg on pg.id = g.perfil_id
      join public.enderecos e on e.id = g.endereco_padrao_id
    union all
    select jsonb_build_object('id', c.perfil_id, 'tipo', 'catador', 'nome', pc.nome,
             'lat', st_y(c.localizacao_atual::geometry), 'lng', st_x(c.localizacao_atual::geometry),
             'situacao', c.situacao)
      from public.catadores c
      join public.perfis pc on pc.id = c.perfil_id
     where c.status_cadastro = 'aprovado' and c.localizacao_atual is not null
    union all
    select jsonb_build_object('id', p.id, 'tipo', 'ponto', 'nome', p.nome,
             'lat', st_y(p.localizacao::geometry), 'lng', st_x(p.localizacao::geometry), 'situacao', null)
      from public.pontos_coleta p where p.ativo
  ) a;

  select coalesce(jsonb_agg(x.j order by x.criada), '[]'::jsonb) into v_rotas from (
    select r.criado_em as criada,
           jsonb_build_object('id', r.id, 'catador_id', r.catador_id, 'status', r.status, 'polyline', r.polyline,
             'paradas', coalesce((select jsonb_agg(jsonb_build_object('ordem', rp.ordem, 'tipo', rp.tipo,
                                    'status', rp.status, 'lat', st_y(rp.localizacao::geometry),
                                    'lng', st_x(rp.localizacao::geometry)) order by rp.ordem)
                                    from public.rota_paradas rp where rp.rota_id = r.id), '[]'::jsonb)) as j
      from public.rotas r
     where r.status in ('planejada','em_andamento')
  ) x;

  select coalesce(jsonb_agg(y.j order by y.criado_em desc, y.id desc), '[]'::jsonb) into v_eventos from (
    select ev.id, ev.criado_em,
           jsonb_build_object('id', ev.id, 'solicitacao_id', ev.solicitacao_id, 'tipo', ev.para_status,
             'de_status', ev.de_status, 'para_status', ev.para_status, 'criado_em', ev.criado_em) as j
      from public.eventos_solicitacao ev
     order by ev.criado_em desc, ev.id desc
     limit p_eventos
  ) y;

  return jsonb_build_object('atores', v_atores, 'rotas', v_rotas, 'eventos', v_eventos);
end;
$$;

-- ---------- demo_criar_catadores (ADM, UC15) ----------
-- Cria p_n catadores ficticios aprovados e disponiveis perto do centro da demo. Sem senha: nao fazem login.
create function public.demo_criar_catadores(p_n int) returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_centro record;
  v_id uuid;
  v_base int;
  v_dx float8;
  v_dy float8;
  v_veiculos text[] := array['carrinho','bicicleta','moto','utilitario'];
begin
  perform public._demo_guarda();
  if p_n is null or p_n not between 1 and 20 then
    raise exception 'parametro_invalido';
  end if;
  select * into v_centro from public._demo_centro();
  select count(*) into v_base from public.demo_atores where origem = 'demo';

  for i in 1..p_n loop
    v_id := gen_random_uuid();
    v_dx := (random() - 0.5) * 5000;     -- +-2,5 km
    v_dy := (random() - 0.5) * 5000;
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
      'demo-' || substr(v_id::text, 1, 8) || '@demo.kaptalixo.local',
      crypt(v_id::text || gen_random_uuid()::text, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('nome', 'Catador Demo ' || (v_base + i)), now(), now(), '', '', '', ''
    );
    insert into public.perfis (id, papel, nome) values (v_id, 'catador', 'Catador Demo ' || (v_base + i));
    insert into public.catadores (perfil_id, tipo, status_cadastro, tipo_veiculo, capacidade_sacos, situacao,
                                  localizacao_atual, localizacao_atualizada_em)
    values (v_id, 'pessoa', 'aprovado', v_veiculos[1 + floor(random() * 4)::int], 6 + floor(random() * 15)::int,
            'disponivel',
            st_setsrid(st_makepoint(v_centro.lng + degrees(v_dx / (6371000 * cos(radians(v_centro.lat)))),
                                    v_centro.lat + degrees(v_dy / 6371000)), 4326)::geography,
            now());
    insert into public.demo_atores (perfil_id, origem) values (v_id, 'demo');
  end loop;
  return p_n;
end;
$$;

-- ---------- demo_criar_pedido (ADM, UC15) ----------
-- Solicitacao ficticia de um gerador ficticio sem pedido ativo; dispara o matching (como criar_solicitacao).
create function public.demo_criar_pedido() returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  g record;
  v_id uuid;
  v_qtd int := 1 + floor(random() * 4)::int;
  v_peso numeric;
  v_rnd bytea;
  v_pin text;
begin
  perform public._demo_guarda();

  select ge.perfil_id, e.localizacao,
         e.logradouro || coalesce(', ' || e.numero, '') as endereco_texto
    into g
    from public.geradores ge
    join public.demo_atores d on d.perfil_id = ge.perfil_id
    join public.enderecos e on e.id = ge.endereco_padrao_id
   where not exists (select 1 from public.solicitacoes s where s.gerador_id = ge.perfil_id
                      and s.status in ('buscando','aceita','a_caminho','no_local','coletada'))
   order by random()
   limit 1;
  if not found then
    raise exception 'sem_gerador_livre';
  end if;

  select v_qtd * coalesce((select (valor ->> 'M')::numeric from public.parametros where chave = 'peso_saco_kg'), 5)
    into v_peso;
  v_rnd := gen_random_bytes(4);
  v_pin := lpad((((get_byte(v_rnd, 0)::bigint << 24) + (get_byte(v_rnd, 1) << 16)
                  + (get_byte(v_rnd, 2) << 8) + get_byte(v_rnd, 3)) % 10000)::text, 4, '0');

  begin
    insert into public.solicitacoes (gerador_id, localizacao, endereco_texto, qtd_sacos, tamanho,
                                     peso_estimado_kg, pin_coleta)
    values (g.perfil_id, g.localizacao, g.endereco_texto, v_qtd, 'M', v_peso, v_pin)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'sem_gerador_livre';
  end;

  insert into public.solicitacao_materiais (solicitacao_id, material_id)
  select v_id, m.id from public.materiais m order by random() limit 1 + floor(random() * 3)::int;

  perform public.gerar_proxima_oferta(v_id);
  return v_id;
end;
$$;

-- ---------- demo_mover_catador (ADM, UC16) ----------
-- Como atualizar_localizacao, mas para um catador ficticio (demo_atores): posicao atual, historico
-- (no maximo 1 ponto a cada 10 s) e posicao exibida ao gerador. Qualquer outro alvo: catador_nao_ficticio.
create function public.demo_mover_catador(p_catador uuid, p_lat float8, p_lng float8) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_pt geography;
  v_rota uuid;
begin
  perform public._demo_guarda();
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'parametro_invalido';
  end if;
  perform 1 from public.catadores c
   where c.perfil_id = p_catador and p_catador is not null
     and exists (select 1 from public.demo_atores d where d.perfil_id = c.perfil_id)
     for update of c;
  if not found then
    raise exception 'catador_nao_ficticio';
  end if;

  v_pt := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update public.catadores set localizacao_atual = v_pt, localizacao_atualizada_em = now()
   where perfil_id = p_catador;

  select id into v_rota from public.rotas
   where catador_id = p_catador and status in ('planejada','em_andamento');
  if not exists (select 1 from public.localizacoes_catador
                  where catador_id = p_catador and registrada_em > now() - interval '10 seconds') then
    insert into public.localizacoes_catador (catador_id, rota_id, localizacao) values (p_catador, v_rota, v_pt);
  end if;

  insert into public.posicoes_atendimento (solicitacao_id, gerador_id, lat, lng, atualizada_em)
  select s.id, s.gerador_id, p_lat, p_lng, now()
    from public.solicitacoes s
   where s.catador_id = p_catador and s.status in ('aceita','a_caminho','no_local')
  on conflict (solicitacao_id) do update
    set lat = excluded.lat, lng = excluded.lng, atualizada_em = excluded.atualizada_em;
end;
$$;

-- ---------- resetar_demo (ADM, UC15): mesma assinatura, agora tambem remove catadores criados pela demo ----------
create or replace function public.resetar_demo() returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._demo_guarda();

  delete from public.entregas where true;                  -- cascata: entrega_itens
  delete from public.rotas where true;                     -- cascata: rota_paradas
  delete from public.solicitacoes where true;              -- cascata: ofertas, avaliacoes, eventos, materiais, posicoes
  delete from public.notificacoes where true;
  delete from public.localizacoes_catador where true;
  -- catadores criados por demo_criar_catadores: remove a conta (cascata: perfis, catadores, demo_atores)
  delete from auth.users where id in (select perfil_id from public.demo_atores where origem = 'demo');

  update public.catadores set avaliacao_media = 0, total_avaliacoes = 0 where true;
  update public.geradores set avaliacao_media = 0, total_avaliacoes = 0 where true;
  update public.catadores c
     set situacao = b.situacao, localizacao_atual = b.localizacao_atual,
         localizacao_atualizada_em = b.localizacao_atualizada_em
    from public.demo_estado_catadores b
   where b.catador_id = c.perfil_id;
  update public.catadores set situacao = 'disponivel'
   where situacao = 'em_rota' and perfil_id not in (select catador_id from public.demo_estado_catadores);
end;
$$;

-- ---------- pontos_proximos (GER, UC02/P-016) ----------
-- Pontos ativos dentro do raio, mais proximos primeiro (max. 20). Sem telefone/operador.
create function public.pontos_proximos(p_lat float8, p_lng float8, p_raio_m float8)
returns table (id uuid, nome text, lat float8, lng float8, distancia_m float8, aberto boolean)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_pt geography;
begin
  if auth.uid() is null then
    raise exception 'sem_permissao';
  end if;
  if p_lat is null or p_lng is null or p_raio_m is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_raio_m <= 0 or p_raio_m > 100000 then
    raise exception 'parametro_invalido';
  end if;
  v_pt := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  return query
    select pc.id, pc.nome, st_y(pc.localizacao::geometry)::float8, st_x(pc.localizacao::geometry)::float8,
           st_distance(pc.localizacao, v_pt)::float8,
           public._ponto_aberto(pc.horario_funcionamento, now())
      from public.pontos_coleta pc
     where pc.ativo and st_dwithin(pc.localizacao, v_pt, p_raio_m)
     order by st_distance(pc.localizacao, v_pt), pc.id
     limit 20;
end;
$$;

-- ---------- v_entrega_a_caminho (PON, P-023 item 3) ----------
-- Entregas a caminho do ponto do operador: rota em andamento com destino no ponto que ele opera.
-- Sem endereco/nome de geradores. `eta` = eta da parada de descarte; `chegou` = descarte no_local.
create view public.v_entrega_a_caminho with (security_barrier = true) as
select r.id as rota_id,
       r.ponto_destino_id as ponto_id,
       pc.nome as catador_nome,
       (select coalesce(sum(s.qtd_sacos), 0)::int
          from public.rota_paradas rc
          join public.solicitacoes s on s.id = rc.solicitacao_id
         where rc.rota_id = r.id and rc.tipo = 'coleta' and rc.status <> 'pulada') as qtd_sacos,
       d.eta,
       (d.status = 'no_local') as chegou
  from public.rotas r
  join public.rota_paradas d on d.rota_id = r.id and d.tipo = 'descarte' and d.ponto_id = r.ponto_destino_id
                            and d.status in ('pendente','a_caminho','no_local')
  join public.perfis pc on pc.id = r.catador_id
 where r.status = 'em_andamento'
   and public.opera_ponto(r.ponto_destino_id);

revoke all on public.v_entrega_a_caminho from public, anon;
grant select on public.v_entrega_a_caminho to authenticated;

-- ---------- grants das RPCs ----------
revoke all on function
  public.demo_snapshot(int), public.demo_criar_catadores(int), public.demo_criar_pedido(),
  public.demo_mover_catador(uuid, float8, float8), public.pontos_proximos(float8, float8, float8)
  from public, anon;
grant execute on function
  public.demo_snapshot(int), public.demo_criar_catadores(int), public.demo_criar_pedido(),
  public.demo_mover_catador(uuid, float8, float8), public.pontos_proximos(float8, float8, float8)
  to authenticated;
