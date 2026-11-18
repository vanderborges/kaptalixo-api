-- T1.8: gerador liberado apos o catador pegar os sacos.
-- Solicitacao ATIVA = buscando, aceita, a_caminho, no_local. 'coletada' deixa de bloquear novo pedido
-- (continua visivel ao gerador para acompanhar/avaliar). Mesmas assinaturas; grants preservados.
drop index if exists public.solic_uma_ativa_por_gerador;
create unique index solic_uma_ativa_por_gerador on public.solicitacoes(gerador_id)
  where status in ('buscando','aceita','a_caminho','no_local');

-- criar_solicitacao (GER): conjunto de ativas sem 'coletada'
create or replace function public.criar_solicitacao(
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
  v_rnd bytea;
begin
  if v_uid is null or public.papel_atual() is distinct from 'gerador' then
    raise exception 'sem_permissao';
  end if;
  if not exists (select 1 from public.geradores where perfil_id = v_uid) then
    raise exception 'sem_permissao';
  end if;
  -- RN01 + limites de tamanho (P-009)
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_qtd_sacos is null or p_qtd_sacos not between 1 and 20 or p_tamanho is null
     or (p_agendada_para is not null and p_agendada_para < now() - interval '5 minutes')
     or length(p_endereco_texto) > 200
     or length(p_observacao) > 500
     or (p_foto_url is not null and (length(p_foto_url) > 500 or p_foto_url !~ '^https://[^[:space:]]+$'))
     or coalesce(array_length(p_materiais, 1), 0) > 20 then
    raise exception 'parametro_invalido';
  end if;
  if exists (select 1 from unnest(coalesce(p_materiais, '{}')) m
              where not exists (select 1 from public.materiais x where x.id = m)) then
    raise exception 'parametro_invalido';
  end if;
  if exists (select 1 from public.solicitacoes where gerador_id = v_uid
              and status in ('buscando','aceita','a_caminho','no_local')) then
    raise exception 'solicitacao_ativa_existente';
  end if;

  -- RN07
  select p_qtd_sacos * coalesce((select (valor ->> p_tamanho::text)::numeric from public.parametros where chave = 'peso_saco_kg'), 5)
    into v_peso;
  -- RN08: PIN de 4 digitos (aleatorio criptografico), so o gerador le (view v_solicitacao_gerador)
  v_rnd := extensions.gen_random_bytes(4);
  v_pin := lpad((((get_byte(v_rnd, 0)::bigint << 24) + (get_byte(v_rnd, 1) << 16)
                  + (get_byte(v_rnd, 2) << 8) + get_byte(v_rnd, 3)) % 10000)::text, 4, '0');

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

-- demo_criar_pedido (ADM): gerador livre = sem solicitacao ativa (sem 'coletada')
create or replace function public.demo_criar_pedido() returns uuid
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
                      and s.status in ('buscando','aceita','a_caminho','no_local'))
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
