-- T1.10: oferta extra a catador em rota (UC10, RN05).
-- Convencao: security definer + search_path explicito; erros curtos e estaveis (raise exception),
-- os mesmos de T1.4 (sem_permissao, oferta_*, catador_indisponivel, sem_capacidade).
-- Ordem de locks (substitui a de T1.4/T1.5 em aceitar_oferta): oferta -> catador -> rota -> solicitacao,
-- igual a das RPCs do ciclo (catador -> rota -> solicitacao); evita deadlock com avancar_parada/cancelar.
-- O parametro de desvio ja existe com a chave `desvio_max_rota_m` (1500 m, T1.2); nao e criado outro.
set search_path = public, extensions;

-- ---------- buscar_catadores_proximos (interna) ----------
-- Mesma assinatura. Dois grupos de candidatos:
--  (a) disponivel + aprovado + capacidade + sem oferta pendente (RN02/RN04/RN10), desvio 0;
--  (b) RN05: em_rota com rota `em_andamento`, aprovado, sem oferta pendente, sem parada `no_local`,
--      capacidade restante >= sacos (capacidade_sacos - sacos das coletas da rota nao puladas, isto e,
--      pendentes + ja coletadas e ainda nao entregues) e desvio estimado <= desvio_max_rota_m, onde
--      desvio = dist(posicao atual, nova coleta) + dist(nova coleta, proxima parada) - dist(posicao atual, proxima parada)
--      (linha reta, geography). Proxima parada = menor `ordem` entre as pendentes/a_caminho.
-- distancia_m = distancia do catador a nova coleta (raio p_raio_m vale para os dois grupos).
-- Ordem: quem nao precisa de desvio (desvio <= 100 m: disponiveis e em_rota "no caminho") primeiro,
-- depois menor distancia, melhor avaliacao. em_rota = true so no grupo (b).
create or replace function public.buscar_catadores_proximos(
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
  ),
  par as (
    select coalesce((select (valor #>> '{}')::numeric from public.parametros
                      where chave = 'desvio_max_rota_m' and jsonb_typeof(valor) = 'number'), 1500) as desvio_max
  ),
  livres as (
    select c.perfil_id as cid, st_distance(c.localizacao_atual, a.g) as dist, c.avaliacao_media as aval,
           0::float8 as desvio, false as na_rota
    from public.catadores c, alvo a
    where c.status_cadastro = 'aprovado'
      and c.situacao = 'disponivel'
      and c.localizacao_atual is not null
      and c.capacidade_sacos >= p_sacos
      and st_dwithin(c.localizacao_atual, a.g, p_raio_m)
      and not (c.perfil_id = any (coalesce(p_excluir, '{}')))
      and not exists (select 1 from public.ofertas o where o.catador_id = c.perfil_id and o.status = 'pendente')
  ),
  em_curso as (
    select c.perfil_id as cid, c.localizacao_atual as pos, c.avaliacao_media as aval,
           c.capacidade_sacos - coalesce(carga.sacos, 0) as restante,
           prox.loc as prox_loc
    from public.catadores c
    join public.rotas r on r.catador_id = c.perfil_id and r.status = 'em_andamento'
    cross join lateral (
      select sum(s.qtd_sacos)::int as sacos
      from public.rota_paradas rp join public.solicitacoes s on s.id = rp.solicitacao_id
      where rp.rota_id = r.id and rp.tipo = 'coleta' and rp.status <> 'pulada') carga
    cross join lateral (
      select rp.localizacao as loc from public.rota_paradas rp
      where rp.rota_id = r.id and rp.status in ('pendente','a_caminho')
      order by rp.ordem limit 1) prox
    where c.status_cadastro = 'aprovado'
      and c.situacao = 'em_rota'
      and c.localizacao_atual is not null
      and not (c.perfil_id = any (coalesce(p_excluir, '{}')))
      and not exists (select 1 from public.ofertas o where o.catador_id = c.perfil_id and o.status = 'pendente')
      and not exists (select 1 from public.rota_paradas rp where rp.rota_id = r.id and rp.status = 'no_local')
  ),
  extras as (
    select e.cid, st_distance(e.pos, a.g) as dist, e.aval,
           st_distance(e.pos, a.g) + st_distance(a.g, e.prox_loc) - st_distance(e.pos, e.prox_loc) as desvio,
           true as na_rota
    from em_curso e, alvo a, par
    where e.restante >= p_sacos
      and st_dwithin(e.pos, a.g, p_raio_m)
      and st_distance(e.pos, a.g) + st_distance(a.g, e.prox_loc) - st_distance(e.pos, e.prox_loc) <= par.desvio_max
  ),
  todos as (
    select * from livres
    union all
    select * from extras
  )
  select t.cid, t.dist, t.aval, t.na_rota
  from todos t
  order by (t.desvio > 100), t.dist, t.aval desc, t.cid
  limit greatest(coalesce(p_limite, 1), 0)
$$;
revoke all on function public.buscar_catadores_proximos(float8, float8, int, int, uuid[], int) from public, anon, authenticated;

-- ---------- aceitar_oferta (CAT) ----------
-- Oferta normal: catador `disponivel` (rota nova ou planejada existente, como antes).
-- Oferta extra (ofertas.na_rota): catador `em_rota` com rota `em_andamento`: a coleta entra na MESMA rota
-- (rota unica por catador), a rota continua em_andamento, a situacao continua em_rota e rotas.versao + 1
-- sinaliza o replanejamento (a edge function planejar-rota reordena as paradas pendentes; paradas ja
-- concluidas nao sao tocadas). Se nao ha coleta em curso (catador indo ao descarte), a nova coleta e promovida
-- a a_caminho. Se a oferta e extra mas o catador ja ficou disponivel (rota encerrada), vale o fluxo normal.
create or replace function public.aceitar_oferta(p_oferta uuid) returns uuid
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
  v_rota_status public.status_rota;
  v_extra boolean := false;
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

  select * into c from public.catadores where perfil_id = v_uid for update;
  if not found or c.status_cadastro <> 'aprovado' then
    raise exception 'catador_indisponivel';
  end if;
  select r.id, r.status into v_rota, v_rota_status from public.rotas r
   where r.catador_id = v_uid and r.status in ('planejada','em_andamento') for update;

  if c.situacao = 'em_rota' and o.na_rota and v_rota_status = 'em_andamento' then
    v_extra := true;
  elsif c.situacao <> 'disponivel' then
    raise exception 'catador_indisponivel';
  end if;

  select * into s from public.solicitacoes where id = o.solicitacao_id for update;
  if s.status <> 'buscando' then
    raise exception 'oferta_indisponivel';
  end if;

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
  -- ordem/ETA/polyline: edge function planejar-rota (le rotas.versao); o app a chama apos o aceite.

  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  values (s.gerador_id, 'oferta_aceita', 'Catador a caminho', 'Um catador aceitou sua coleta.',
          jsonb_build_object('solicitacao_id', s.id));

  if v_extra then
    perform public._promover_proxima_parada(v_rota);
  end if;
  return v_rota;
end;
$$;
revoke all on function public.aceitar_oferta(uuid) from public, anon;
grant execute on function public.aceitar_oferta(uuid) to authenticated;
