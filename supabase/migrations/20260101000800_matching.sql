-- T1.4: matching e ofertas (UC03/UC04/UC05; RN01-RN04, RN08, RN10).
-- Convencao: tudo security definer + search_path explicito; erros curtos e estaveis via raise exception:
--   sem_permissao, parametro_invalido, solicitacao_ativa_existente, oferta_inexistente,
--   oferta_indisponivel, oferta_expirada, catador_indisponivel, sem_capacidade.
-- Ordem de locks (evita deadlock): oferta -> solicitacao -> catador.
-- Internas (buscar_catadores_proximos, gerar_proxima_oferta): SEM execute para authenticated
-- (a primeira vazaria posicoes de catadores; a segunda queimaria tentativas alheias).
set search_path = public, extensions;

-- ---------- buscar_catadores_proximos (interna) ----------
-- Disponivel + aprovado (RN02/RN10) + com capacidade (RN04) + sem oferta pendente de outra solicitacao.
-- Ordena por distancia (aproximacao do tempo de rota) e depois por avaliacao. em_rota fica false
-- ate o UC10 (RN05, oferta extra a catador em rota) ser implementado.
create function public.buscar_catadores_proximos(
  p_lat float8, p_lng float8, p_raio_m int, p_sacos int,
  p_excluir uuid[] default '{}', p_limite int default 1)
returns table (catador_id uuid, distancia_m float8, avaliacao_media numeric, em_rota boolean)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with alvo as (
    select st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography as g
  )
  select c.perfil_id,
         st_distance(c.localizacao_atual, a.g),
         c.avaliacao_media,
         false
  from public.catadores c, alvo a
  where c.status_cadastro = 'aprovado'
    and c.situacao = 'disponivel'
    and c.localizacao_atual is not null
    and c.capacidade_sacos >= p_sacos
    and st_dwithin(c.localizacao_atual, a.g, p_raio_m)
    and not (c.perfil_id = any (coalesce(p_excluir, '{}')))
    and not exists (select 1 from public.ofertas o where o.catador_id = c.perfil_id and o.status = 'pendente')
  order by st_distance(c.localizacao_atual, a.g), c.avaliacao_media desc, c.perfil_id
  limit greatest(coalesce(p_limite, 1), 0)
$$;

-- ---------- gerar_proxima_oferta (interna / job) ----------
create function public.gerar_proxima_oferta(p_solicitacao uuid) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s public.solicitacoes%rowtype;
  v_oferta uuid;
  v_max int;
  v_validade int;
  v_raio int;
  v_cand record;
  v_lat float8;
  v_lng float8;
  v_excl uuid[];
begin
  select * into s from public.solicitacoes where id = p_solicitacao for update;
  if not found or s.status <> 'buscando' then
    return null;
  end if;

  select o.id into v_oferta from public.ofertas o
   where o.solicitacao_id = s.id and o.status = 'pendente';
  if found then
    return v_oferta;
  end if;

  select coalesce((select (valor #>> '{}')::int from public.parametros where chave = 'max_ofertas_por_solicitacao'), 5) into v_max;
  select coalesce((select (valor #>> '{}')::int from public.parametros where chave = 'oferta_validade_s'), 45) into v_validade;

  if s.tentativas_oferta < v_max then
    v_lat := st_y(s.localizacao::geometry);
    v_lng := st_x(s.localizacao::geometry);
    select coalesce(array_agg(o.catador_id), '{}') into v_excl from public.ofertas o where o.solicitacao_id = s.id;

    for v_raio in
      select (r #>> '{}')::int
      from public.parametros p, jsonb_array_elements(p.valor) r
      where p.chave = 'raios_busca_m'
      order by (r #>> '{}')::int
    loop
      select * into v_cand from public.buscar_catadores_proximos(v_lat, v_lng, v_raio, s.qtd_sacos, v_excl, 1);
      exit when v_cand.catador_id is not null;
    end loop;

    if v_cand.catador_id is not null then
      insert into public.ofertas (solicitacao_id, catador_id, ordem, status, distancia_m, eta_s, na_rota, expira_em)
      values (s.id, v_cand.catador_id, s.tentativas_oferta + 1, 'pendente',
              round(v_cand.distancia_m)::int,
              round(v_cand.distancia_m / 5.0)::int,   -- ~18 km/h em linha reta; refinado pela rota depois
              v_cand.em_rota, now() + make_interval(secs => v_validade))
      returning id into v_oferta;

      update public.solicitacoes set tentativas_oferta = tentativas_oferta + 1 where id = s.id;

      insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
      values (v_cand.catador_id, 'nova_oferta', 'Nova coleta perto de voce',
              s.qtd_sacos || ' saco(s) de reciclaveis', jsonb_build_object('oferta_id', v_oferta, 'solicitacao_id', s.id));
      return v_oferta;
    end if;
  end if;

  -- RN03: sem candidato no raio maximo ou ofertas esgotadas
  update public.solicitacoes set status = 'sem_catador' where id = s.id;
  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  values (s.gerador_id, 'sem_catador', 'Nenhum catador disponivel',
          'Tente novamente em alguns minutos.', jsonb_build_object('solicitacao_id', s.id));
  return null;
end;
$$;

-- ---------- criar_solicitacao (GER) ----------
create function public.criar_solicitacao(
  p_lat float8, p_lng float8, p_endereco_texto text, p_qtd_sacos int,
  p_tamanho public.tamanho_saco default 'M',
  p_materiais smallint[] default '{}',
  p_observacao text default null, p_foto_url text default null,
  p_agendada_para timestamptz default null)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_peso numeric;
  v_pin text;
begin
  if v_uid is null or public.papel_atual() is distinct from 'gerador' then
    raise exception 'sem_permissao';
  end if;
  if not exists (select 1 from public.geradores where perfil_id = v_uid) then
    raise exception 'sem_permissao';
  end if;
  -- RN01
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_qtd_sacos is null or p_qtd_sacos not between 1 and 20 or p_tamanho is null
     or (p_agendada_para is not null and p_agendada_para < now() - interval '5 minutes') then
    raise exception 'parametro_invalido';
  end if;
  if exists (select 1 from unnest(coalesce(p_materiais, '{}')) m
              where not exists (select 1 from public.materiais x where x.id = m)) then
    raise exception 'parametro_invalido';
  end if;
  if exists (select 1 from public.solicitacoes where gerador_id = v_uid
              and status in ('buscando','aceita','a_caminho','no_local','coletada')) then
    raise exception 'solicitacao_ativa_existente';
  end if;

  -- RN07
  select p_qtd_sacos * coalesce((select (valor ->> p_tamanho::text)::numeric from public.parametros where chave = 'peso_saco_kg'), 5)
    into v_peso;
  -- RN08: PIN de 4 digitos, so o gerador le (view v_solicitacao_gerador)
  v_pin := lpad(floor(random() * 10000)::int::text, 4, '0');

  begin
    insert into public.solicitacoes (gerador_id, localizacao, endereco_texto, qtd_sacos, tamanho,
                                     peso_estimado_kg, observacao, foto_url, agendada_para, pin_coleta)
    values (v_uid, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_endereco_texto, p_qtd_sacos,
            p_tamanho, v_peso, p_observacao, p_foto_url, p_agendada_para, v_pin)
    returning id into v_id;
  exception when unique_violation then   -- corrida entre duas chamadas do mesmo gerador
    raise exception 'solicitacao_ativa_existente';
  end;

  insert into public.solicitacao_materiais (solicitacao_id, material_id)
  select v_id, m from (select distinct unnest(coalesce(p_materiais, '{}')) m) x;

  perform public.gerar_proxima_oferta(v_id);
  return v_id;
end;
$$;

-- ---------- aceitar_oferta (CAT) ----------
create function public.aceitar_oferta(p_oferta uuid) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  o public.ofertas%rowtype;
  s public.solicitacoes%rowtype;
  c public.catadores%rowtype;
  v_rota uuid;
  v_ordem int;
  v_carga int;
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;

  -- primeiro aceite vence: a linha da oferta serializa os concorrentes
  select * into o from public.ofertas where id = p_oferta for update;
  if not found or o.catador_id <> v_uid then
    raise exception 'oferta_inexistente';
  end if;
  if o.status <> 'pendente' then
    raise exception 'oferta_indisponivel';
  end if;
  if o.expira_em <= now() then
    raise exception 'oferta_expirada';
  end if;

  select * into s from public.solicitacoes where id = o.solicitacao_id for update;
  if s.status <> 'buscando' then
    raise exception 'oferta_indisponivel';
  end if;

  select * into c from public.catadores where perfil_id = v_uid for update;
  if c.status_cadastro <> 'aprovado' or c.situacao <> 'disponivel' then
    raise exception 'catador_indisponivel';
  end if;

  select r.id into v_rota from public.rotas r
   where r.catador_id = v_uid and r.status in ('planejada','em_andamento');
  select coalesce(sum(x.qtd_sacos), 0) into v_carga
    from public.rota_paradas rp join public.solicitacoes x on x.id = rp.solicitacao_id
   where rp.rota_id = v_rota and rp.tipo = 'coleta' and rp.status <> 'pulada';
  if v_carga + s.qtd_sacos > c.capacidade_sacos then      -- RN04
    raise exception 'sem_capacidade';
  end if;

  update public.ofertas set status = 'aceita', respondida_em = now() where id = o.id;
  update public.solicitacoes set status = 'aceita', catador_id = v_uid where id = s.id;
  update public.catadores set situacao = 'em_rota' where perfil_id = v_uid;

  if v_rota is null then
    insert into public.rotas (catador_id) values (v_uid) returning id into v_rota;
  else
    update public.rotas set versao = versao + 1 where id = v_rota;
  end if;
  select coalesce(max(ordem), 0) + 1 into v_ordem from public.rota_paradas where rota_id = v_rota;
  insert into public.rota_paradas (rota_id, ordem, tipo, solicitacao_id, localizacao)
  values (v_rota, v_ordem, 'coleta', s.id, s.localizacao);
  -- A ordem/ETA/polyline vem da edge function planejar-rota (T4.2), que le rotas.versao; nada e enfileirado.

  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  values (s.gerador_id, 'oferta_aceita', 'Catador a caminho', 'Um catador aceitou sua coleta.',
          jsonb_build_object('solicitacao_id', s.id));
  return v_rota;
end;
$$;

-- ---------- recusar_oferta (CAT) ----------
create function public.recusar_oferta(p_oferta uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  o public.ofertas%rowtype;
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;
  select * into o from public.ofertas where id = p_oferta for update;
  if not found or o.catador_id <> v_uid then
    raise exception 'oferta_inexistente';
  end if;
  if o.status <> 'pendente' then
    raise exception 'oferta_indisponivel';
  end if;
  update public.ofertas set status = 'recusada', respondida_em = now() where id = o.id;
  perform public.gerar_proxima_oferta(o.solicitacao_id);
end;
$$;

-- ---------- expirar_ofertas (pg_cron / app) ----------
-- Idempotente; pula ofertas travadas por um aceite em andamento. Retorna quantas expirou.
create function public.expirar_ofertas() returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  o record;
  n int := 0;
begin
  if auth.uid() is not null and public.papel_atual() is null then
    raise exception 'sem_permissao';
  end if;
  for o in
    select id, solicitacao_id from public.ofertas
     where status = 'pendente' and expira_em <= now()
     order by expira_em
     for update skip locked
  loop
    update public.ofertas set status = 'expirada', respondida_em = now() where id = o.id;
    perform public.gerar_proxima_oferta(o.solicitacao_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke all on function public.buscar_catadores_proximos(float8, float8, int, int, uuid[], int) from public, anon, authenticated;
revoke all on function public.gerar_proxima_oferta(uuid) from public, anon, authenticated;
revoke all on function public.criar_solicitacao(float8, float8, text, int, public.tamanho_saco, smallint[], text, text, timestamptz) from public, anon;
revoke all on function public.aceitar_oferta(uuid), public.recusar_oferta(uuid), public.expirar_ofertas() from public, anon;
grant execute on function public.criar_solicitacao(float8, float8, text, int, public.tamanho_saco, smallint[], text, text, timestamptz) to authenticated;
grant execute on function public.aceitar_oferta(uuid), public.recusar_oferta(uuid), public.expirar_ofertas() to authenticated;

-- ---------- job: expira ofertas a cada 10 s (45 s de validade + ate 10 s de atraso) ----------
-- O app tambem pode chamar expirar_ofertas() (rede de seguranca se o pg_cron estiver parado).
select cron.schedule('kaptalixo-expirar-ofertas', '10 seconds', 'select public.expirar_ofertas()');
