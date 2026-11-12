-- T1.5: ciclo da coleta (UC08, UC11-UC14; RN08-RN12) + ajustes P-005/P-007/P-009.
-- Convencao: tudo security definer + search_path explicito; erros curtos e estaveis via raise exception:
--   sem_permissao, parametro_invalido, cadastro_nao_aprovado, catador_em_rota, catador_indisponivel,
--   rota_inexistente, rota_invalida, parada_inexistente, parada_invalida, coletas_pendentes,
--   ponto_inexistente, material_sem_preco, solicitacao_inexistente, solicitacao_nao_cancelavel,
--   avaliacao_indisponivel, avaliacao_duplicada, modo_demo_desativado.
-- PIN errado/bloqueado NAO e excecao: o erro e devolvido em jsonb (resultado), porque um raise desfaria
-- o incremento de pin_erros e o bloqueio.
-- Ordem de locks (evita deadlock): oferta -> solicitacao (aceitar_oferta) e catador -> rota -> solicitacao
-- (RPCs desta migration, via _travar_rota). Quem cancela uma solicitacao em `buscando` trava a oferta antes.
set search_path = public, extensions;

-- ---------- P-005: v_rota_catador nao devolve polyline/alternativas de rota encerrada ----------
create or replace view public.v_rota_catador with (security_barrier = true) as
select r.id, r.catador_id, r.status, r.ponto_destino_id,
       case when r.status in ('planejada','em_andamento') then r.alternativas_ponto end as alternativas_ponto,
       r.distancia_total_m, r.duracao_total_s,
       case when r.status in ('planejada','em_andamento') then r.polyline end as polyline,
       r.origem_calculo, r.versao, r.criado_em, r.iniciada_em, r.concluida_em
  from public.rotas r
 where r.catador_id = auth.uid();

-- ---------- posicao atual do catador para o gerador (P-004 f) ----------
-- Tabela sanitizada (so lat/lng/hora) para o gerador dono, enquanto a coleta esta aceita/a_caminho/no_local.
-- Alimentada por atualizar_localizacao e por trigger (aceite/devolucao/encerramento). Publicada no Realtime.
create table public.posicoes_atendimento (
  solicitacao_id uuid primary key references public.solicitacoes(id) on delete cascade,
  gerador_id     uuid not null references public.geradores(perfil_id) on delete cascade,
  lat            float8 not null,
  lng            float8 not null,
  atualizada_em  timestamptz not null default now()
);
alter table public.posicoes_atendimento enable row level security;
create policy posicoes_gerador_select on public.posicoes_atendimento for select to authenticated
  using (gerador_id = (select auth.uid())
         and exists (select 1 from public.solicitacoes s
                      where s.id = solicitacao_id and s.status in ('aceita','a_caminho','no_local')));
revoke all on public.posicoes_atendimento from public, anon, authenticated;
grant select on public.posicoes_atendimento to authenticated;
alter publication supabase_realtime add table public.posicoes_atendimento;

create function public.tg_posicao_atendimento() returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.status in ('aceita','a_caminho','no_local') and new.catador_id is not null then
    insert into public.posicoes_atendimento (solicitacao_id, gerador_id, lat, lng, atualizada_em)
    select new.id, new.gerador_id, st_y(c.localizacao_atual::geometry), st_x(c.localizacao_atual::geometry),
           coalesce(c.localizacao_atualizada_em, now())
      from public.catadores c
     where c.perfil_id = new.catador_id and c.localizacao_atual is not null
    on conflict (solicitacao_id) do update
      set lat = excluded.lat, lng = excluded.lng, atualizada_em = excluded.atualizada_em;
  else
    delete from public.posicoes_atendimento where solicitacao_id = new.id;
  end if;
  return new;
end;
$$;
revoke all on function public.tg_posicao_atendimento() from public, anon, authenticated;
create trigger trg_solicitacao_posicao
  after insert or update of status, catador_id on public.solicitacoes
  for each row execute function public.tg_posicao_atendimento();

-- ---------- estado base da demo (usado por resetar_demo; preenchido pelo seed) ----------
create table public.demo_estado_catadores (
  catador_id                uuid primary key references public.catadores(perfil_id) on delete cascade,
  situacao                  public.disponibilidade not null,
  localizacao_atual         geography(Point,4326),
  localizacao_atualizada_em timestamptz
);
alter table public.demo_estado_catadores enable row level security;   -- sem policies: so funcoes definer
revoke all on public.demo_estado_catadores from public, anon, authenticated;

-- ---------- helpers internos (sem execute para authenticated) ----------
-- Trava catador e depois rota (ordem fixa). Devolve linha com id nulo se a rota nao existe.
create function public._travar_rota(p_rota uuid) returns public.rotas
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cat uuid;
  r public.rotas;
begin
  select catador_id into v_cat from public.rotas where id = p_rota;
  if not found then
    return null;
  end if;
  perform 1 from public.catadores where perfil_id = v_cat for update;
  select * into r from public.rotas where id = p_rota for update;
  return r;
end;
$$;

-- Se nenhuma coleta esta em curso (a_caminho/no_local), a proxima pendente (menor ordem) passa a a_caminho.
create function public._promover_proxima_parada(p_rota uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_parada uuid;
  v_solic uuid;
  v_ger uuid;
begin
  if exists (select 1 from public.rota_paradas
              where rota_id = p_rota and tipo = 'coleta' and status in ('a_caminho','no_local')) then
    return;
  end if;
  select id, solicitacao_id into v_parada, v_solic from public.rota_paradas
   where rota_id = p_rota and tipo = 'coleta' and status = 'pendente'
   order by ordem limit 1;
  if v_parada is null then
    return;
  end if;
  update public.rota_paradas set status = 'a_caminho' where id = v_parada;
  update public.solicitacoes set status = 'a_caminho' where id = v_solic and status = 'aceita'
  returning gerador_id into v_ger;
  if v_ger is not null then
    insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
    values (v_ger, 'catador_a_caminho', 'Catador a caminho', 'O catador esta indo ate voce.',
            jsonb_build_object('solicitacao_id', v_solic));
  end if;
end;
$$;

-- Chamada depois de marcar uma parada de coleta como pulada: sinaliza recalculo (versao), encerra a rota
-- se nao sobrou nenhuma coleta (catador volta a disponivel) ou promove a proxima parada.
create function public._apos_remocao_parada(p_rota uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cat uuid;
  v_status public.status_rota;
begin
  update public.rotas set versao = versao + 1 where id = p_rota
  returning catador_id, status into v_cat, v_status;
  if not exists (select 1 from public.rota_paradas
                  where rota_id = p_rota and tipo = 'coleta' and status <> 'pulada') then
    update public.rotas set status = 'cancelada', concluida_em = now() where id = p_rota;
    update public.rota_paradas set status = 'pulada' where rota_id = p_rota and tipo = 'descarte' and status <> 'concluida';
    update public.catadores set situacao = 'disponivel' where perfil_id = v_cat and situacao = 'em_rota';
  elsif v_status = 'em_andamento' then
    perform public._promover_proxima_parada(p_rota);
  end if;
end;
$$;

-- Job de retencao (P-005/P-004 k): apaga posicoes com mais de 7 dias.
create function public.limpar_localizacoes_antigas() returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  n int;
begin
  delete from public.localizacoes_catador where registrada_em < now() - interval '7 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public._travar_rota(uuid), public._promover_proxima_parada(uuid),
  public._apos_remocao_parada(uuid), public.limpar_localizacoes_antigas() from public, anon, authenticated;

select cron.schedule('kaptalixo-limpar-localizacoes', '0 3 * * *', 'select public.limpar_localizacoes_antigas()');

-- ---------- alternar_disponibilidade (CAT, UC14, RN10) ----------
create function public.alternar_disponibilidade(p_disponivel boolean) returns public.disponibilidade
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  c public.catadores%rowtype;
  v_novo public.disponibilidade;
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;
  if p_disponivel is null then
    raise exception 'parametro_invalido';
  end if;
  select * into c from public.catadores where perfil_id = v_uid for update;
  if not found then
    raise exception 'sem_permissao';
  end if;
  if p_disponivel and c.status_cadastro <> 'aprovado' then      -- RN10
    raise exception 'cadastro_nao_aprovado';
  end if;
  if c.situacao = 'em_rota' then
    raise exception 'catador_em_rota';
  end if;
  v_novo := case when p_disponivel then 'disponivel' else 'offline' end;
  update public.catadores set situacao = v_novo where perfil_id = v_uid;
  return v_novo;
end;
$$;

-- ---------- atualizar_localizacao (CAT, UC08/UC14) ----------
-- Atualiza a posicao atual, grava historico (no maximo 1 ponto a cada 10 s) e alimenta a posicao
-- exibida ao gerador. Catador offline nao envia posicao (LGPD).
create function public.atualizar_localizacao(p_lat float8, p_lng float8, p_rota uuid default null) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  c public.catadores%rowtype;
  v_rota uuid;
  v_pt geography;
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'parametro_invalido';
  end if;
  select * into c from public.catadores where perfil_id = v_uid for update;
  if not found then
    raise exception 'sem_permissao';
  end if;
  if c.situacao = 'offline' then
    raise exception 'catador_indisponivel';
  end if;
  if p_rota is not null then
    select id into v_rota from public.rotas
     where id = p_rota and catador_id = v_uid and status in ('planejada','em_andamento');
    if not found then
      raise exception 'rota_inexistente';
    end if;
  else
    select id into v_rota from public.rotas
     where catador_id = v_uid and status in ('planejada','em_andamento');
  end if;

  v_pt := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update public.catadores set localizacao_atual = v_pt, localizacao_atualizada_em = now() where perfil_id = v_uid;

  if not exists (select 1 from public.localizacoes_catador
                  where catador_id = v_uid and registrada_em > now() - interval '10 seconds') then
    insert into public.localizacoes_catador (catador_id, rota_id, localizacao) values (v_uid, v_rota, v_pt);
  end if;

  insert into public.posicoes_atendimento (solicitacao_id, gerador_id, lat, lng, atualizada_em)
  select s.id, s.gerador_id, p_lat, p_lng, now()
    from public.solicitacoes s
   where s.catador_id = v_uid and s.status in ('aceita','a_caminho','no_local')
  on conflict (solicitacao_id) do update
    set lat = excluded.lat, lng = excluded.lng, atualizada_em = excluded.atualizada_em;
end;
$$;

-- ---------- iniciar_rota (CAT, UC08) ----------
create function public.iniciar_rota(p_rota uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  r public.rotas;
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;
  r := public._travar_rota(p_rota);
  if r.id is null or r.catador_id <> v_uid then
    raise exception 'rota_inexistente';
  end if;
  if r.status <> 'planejada' then
    raise exception 'rota_invalida';
  end if;
  update public.rotas set status = 'em_andamento', iniciada_em = now() where id = r.id;
  perform public._promover_proxima_parada(r.id);
end;
$$;

-- ---------- avancar_parada (CAT, UC08, RN08) ----------
-- Acoes: cheguei | concluir (exige PIN) | pular (so coleta; devolve a solicitacao a fila).
-- Retorno jsonb: {"resultado": "ok" | "pin_incorreto" | "pin_bloqueado", ...}. Nunca devolve o PIN.
create function public.avancar_parada(p_parada uuid, p_acao text, p_pin text default null, p_motivo text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_rota_id uuid;
  r public.rotas;
  pa public.rota_paradas%rowtype;
  s public.solicitacoes%rowtype;
  v_max int;
  v_bloq int;
  v_erros int;
  v_ate timestamptz;
  v_motivo text := nullif(btrim(p_motivo), '');
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;
  if p_acao is null or p_acao not in ('cheguei','concluir','pular') or length(coalesce(v_motivo, '')) > 200 then
    raise exception 'parametro_invalido';
  end if;

  select rota_id into v_rota_id from public.rota_paradas where id = p_parada;
  if not found then
    raise exception 'parada_inexistente';
  end if;
  r := public._travar_rota(v_rota_id);
  if r.id is null or r.catador_id <> v_uid then
    raise exception 'parada_inexistente';
  end if;
  select * into pa from public.rota_paradas where id = p_parada for update;
  if r.status <> 'em_andamento' then
    raise exception 'rota_invalida';
  end if;
  if (p_acao = 'cheguei' and pa.status not in ('pendente','a_caminho'))
     or (p_acao = 'concluir' and pa.status <> 'no_local')
     or (p_acao = 'pular' and pa.status not in ('pendente','a_caminho','no_local')) then
    raise exception 'parada_invalida';
  end if;

  -- parada de descarte: so "cheguei" (a conclusao e feita por registrar_entrega)
  if pa.tipo = 'descarte' then
    if p_acao <> 'cheguei' then
      raise exception 'parada_invalida';
    end if;
    if exists (select 1 from public.rota_paradas
                where rota_id = r.id and tipo = 'coleta' and status in ('pendente','a_caminho','no_local')) then
      raise exception 'coletas_pendentes';
    end if;
    update public.rota_paradas set status = 'no_local', chegou_em = now() where id = pa.id;
    return jsonb_build_object('resultado', 'ok');
  end if;

  select * into s from public.solicitacoes where id = pa.solicitacao_id for update;

  if p_acao = 'cheguei' then
    if s.status not in ('aceita','a_caminho')
       or exists (select 1 from public.rota_paradas where rota_id = r.id and tipo = 'coleta' and status = 'no_local') then
      raise exception 'parada_invalida';
    end if;
    update public.rota_paradas set status = 'no_local', chegou_em = now() where id = pa.id;
    update public.solicitacoes set status = 'no_local' where id = s.id;
    insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
    values (s.gerador_id, 'catador_chegou', 'Catador chegou', 'Informe o PIN ao catador para confirmar a coleta.',
            jsonb_build_object('solicitacao_id', s.id));
    return jsonb_build_object('resultado', 'ok');

  elsif p_acao = 'concluir' then
    if p_pin is null or p_pin !~ '^[0-9]{4}$' then
      raise exception 'parametro_invalido';
    end if;
    if s.status <> 'no_local' then
      raise exception 'parada_invalida';
    end if;
    -- RN08: so o PIN correto confirma a coleta
    if s.bloqueio_pin_ate is not null and s.bloqueio_pin_ate > now() then
      return jsonb_build_object('resultado', 'pin_bloqueado', 'bloqueio_ate', s.bloqueio_pin_ate);
    end if;
    if s.pin_coleta is distinct from p_pin then
      select coalesce((select (valor #>> '{}')::int from public.parametros where chave = 'pin_max_erros'), 3) into v_max;
      select coalesce((select (valor #>> '{}')::int from public.parametros where chave = 'pin_bloqueio_s'), 120) into v_bloq;
      v_erros := s.pin_erros + 1;
      if v_erros >= v_max then
        v_ate := now() + make_interval(secs => v_bloq);
        update public.solicitacoes set pin_erros = 0, bloqueio_pin_ate = v_ate where id = s.id;
        insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
        select p.id, 'alerta_pin_bloqueado', 'PIN bloqueado',
               'Tentativas de PIN esgotadas em uma coleta.', jsonb_build_object('solicitacao_id', s.id)
          from public.perfis p where p.papel = 'admin';
        return jsonb_build_object('resultado', 'pin_bloqueado', 'bloqueio_ate', v_ate);
      end if;
      update public.solicitacoes set pin_erros = v_erros where id = s.id;
      return jsonb_build_object('resultado', 'pin_incorreto', 'tentativas_restantes', v_max - v_erros);
    end if;

    update public.rota_paradas set status = 'concluida', concluida_em = now() where id = pa.id;
    update public.solicitacoes set status = 'coletada', pin_erros = 0, bloqueio_pin_ate = null where id = s.id;
    insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
    values (s.gerador_id, 'coleta_confirmada', 'Coleta confirmada', 'Obrigado por reciclar! Avalie o catador.',
            jsonb_build_object('solicitacao_id', s.id));
    perform public._promover_proxima_parada(r.id);
    return jsonb_build_object('resultado', 'ok');

  else  -- pular: gerador ausente; a solicitacao volta a fila sem este catador (UC08)
    update public.rota_paradas set status = 'pulada' where id = pa.id;
    update public.solicitacoes
       set status = 'buscando', catador_id = null, pin_erros = 0, bloqueio_pin_ate = null
     where id = s.id;
    insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
    values (s.gerador_id, 'catador_nao_atendeu', 'Procurando outro catador',
            'O catador nao conseguiu concluir a coleta.', jsonb_build_object('solicitacao_id', s.id, 'motivo', v_motivo));
    perform public._apos_remocao_parada(r.id);
    perform public.gerar_proxima_oferta(s.id);
    return jsonb_build_object('resultado', 'ok');
  end if;
end;
$$;

-- ---------- registrar_entrega (PON, UC11, RN11) ----------
create function public.registrar_entrega(p_rota uuid, p_itens jsonb) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_ponto uuid;
  r public.rotas;
  v_entrega uuid;
  it record;
  v_preco numeric;
  v_valor numeric;
  v_peso_total numeric := 0;
  v_valor_total numeric := 0;
begin
  if v_uid is null or public.papel_atual() is distinct from 'ponto' then
    raise exception 'sem_permissao';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 20 then
    raise exception 'parametro_invalido';
  end if;
  begin
    if exists (select 1 from jsonb_to_recordset(p_itens) as m(material_id smallint, peso_kg numeric)
                where m.material_id is null or m.peso_kg is null
                   or round(m.peso_kg, 2) <= 0 or m.peso_kg > 100000) then
      raise exception 'parametro_invalido';
    end if;
  exception when data_exception then
    raise exception 'parametro_invalido';
  end;

  -- permissao antes de travar qualquer coisa: so o operador do ponto de destino da rota
  select ponto_destino_id into v_ponto from public.rotas where id = p_rota;
  if not found or v_ponto is null or not public.opera_ponto(v_ponto) then
    raise exception 'rota_inexistente';
  end if;
  r := public._travar_rota(p_rota);
  if r.status <> 'em_andamento' then
    raise exception 'rota_invalida';
  end if;
  if exists (select 1 from public.rota_paradas
              where rota_id = r.id and tipo = 'coleta' and status in ('pendente','a_caminho','no_local')) then
    raise exception 'coletas_pendentes';
  end if;

  insert into public.entregas (rota_id, ponto_id, catador_id, registrada_por)
  values (r.id, r.ponto_destino_id, r.catador_id, v_uid)
  returning id into v_entrega;

  -- RN11: valor = peso x preco/kg vigente (por material; pesos repetidos somam), 2 casas
  for it in
    select m.material_id, sum(round(m.peso_kg, 2)) as peso_kg
      from jsonb_to_recordset(p_itens) as m(material_id smallint, peso_kg numeric)
     group by m.material_id
     order by m.material_id
  loop
    select preco_kg into v_preco from public.ponto_precos
     where ponto_id = r.ponto_destino_id and material_id = it.material_id;
    if not found then
      raise exception 'material_sem_preco';
    end if;
    v_valor := round(it.peso_kg * v_preco, 2);
    insert into public.entrega_itens (entrega_id, material_id, peso_kg, preco_kg, valor)
    values (v_entrega, it.material_id, it.peso_kg, v_preco, v_valor);
    v_peso_total := v_peso_total + it.peso_kg;
    v_valor_total := v_valor_total + v_valor;
  end loop;
  update public.entregas set peso_total_kg = v_peso_total, valor_total = v_valor_total where id = v_entrega;

  with up as (
    update public.solicitacoes set status = 'entregue'
     where status = 'coletada'
       and id in (select solicitacao_id from public.rota_paradas
                   where rota_id = r.id and tipo = 'coleta' and status = 'concluida')
    returning id, gerador_id
  )
  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  select gerador_id, 'coleta_entregue', 'Material entregue', 'Seu material foi entregue ao ponto de coleta.',
         jsonb_build_object('solicitacao_id', id)
    from up;

  update public.rota_paradas set status = 'concluida', chegou_em = coalesce(chegou_em, now()), concluida_em = now()
   where rota_id = r.id and tipo = 'descarte' and status <> 'concluida';
  update public.rotas set status = 'concluida', concluida_em = now() where id = r.id;
  update public.catadores set situacao = 'disponivel' where perfil_id = r.catador_id and situacao = 'em_rota';

  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  values (r.catador_id, 'entrega_registrada', 'Entrega registrada', 'Valor total: R$ ' || v_valor_total,
          jsonb_build_object('entrega_id', v_entrega, 'valor_total', v_valor_total));
  return v_entrega;
end;
$$;

-- ---------- cancelar_solicitacao (GER/CAT, UC12, RN09) ----------
create function public.cancelar_solicitacao(p_solicitacao uuid, p_motivo text default null) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_papel public.papel_usuario := public.papel_atual();
  v_motivo text := nullif(btrim(p_motivo), '');
  s public.solicitacoes%rowtype;
  v_parada public.rota_paradas%rowtype;
  r public.rotas;
  v_cat uuid;
begin
  if v_uid is null or v_papel is null or v_papel not in ('gerador','catador') then
    raise exception 'sem_permissao';
  end if;
  if length(coalesce(v_motivo, '')) > 200 then
    raise exception 'parametro_invalido';
  end if;

  select * into s from public.solicitacoes where id = p_solicitacao;      -- leitura sem lock (descobre o que travar)
  if not found
     or (v_papel = 'gerador' and s.gerador_id <> v_uid)
     or (v_papel = 'catador' and s.catador_id is distinct from v_uid) then
    raise exception 'solicitacao_inexistente';
  end if;

  perform 1 from public.ofertas where solicitacao_id = s.id and status = 'pendente' for update;
  select * into v_parada from public.rota_paradas rp
   where rp.solicitacao_id = s.id and rp.status in ('pendente','a_caminho','no_local')
     and exists (select 1 from public.rotas x where x.id = rp.rota_id and x.status in ('planejada','em_andamento'))
   limit 1;
  if v_parada.id is not null then
    r := public._travar_rota(v_parada.rota_id);
  end if;
  select * into s from public.solicitacoes where id = p_solicitacao for update;

  if v_papel = 'catador' and s.catador_id is distinct from v_uid then
    raise exception 'solicitacao_inexistente';
  end if;
  if (v_papel = 'gerador' and s.status not in ('buscando','aceita','a_caminho','no_local'))
     or (v_papel = 'catador' and s.status not in ('aceita','a_caminho','no_local')) then
    raise exception 'solicitacao_nao_cancelavel';
  end if;
  v_cat := s.catador_id;

  if v_papel = 'gerador' then
    update public.ofertas set status = 'cancelada', respondida_em = now()
     where solicitacao_id = s.id and status = 'pendente';
    update public.solicitacoes
       set status = 'cancelada',
           motivo_cancelamento = case when v_cat is null then v_motivo
                                      else coalesce(v_motivo, 'sem_motivo_informado') end
     where id = s.id;
    if v_cat is not null then
      insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
      values (v_cat, 'solicitacao_cancelada', 'Coleta cancelada', 'O gerador cancelou esta coleta.',
              jsonb_build_object('solicitacao_id', s.id, 'motivo', v_motivo));
      if v_parada.id is not null then
        update public.rota_paradas set status = 'pulada' where id = v_parada.id;
        perform public._apos_remocao_parada(v_parada.rota_id);
      end if;
    end if;
  else
    -- RN09: catador que cancela devolve a solicitacao a fila, sem receber nova oferta dela
    -- (a oferta aceita permanece e entra em p_excluir na busca)
    if v_parada.id is not null then
      update public.rota_paradas set status = 'pulada' where id = v_parada.id;
    end if;
    update public.solicitacoes
       set status = 'buscando', catador_id = null, pin_erros = 0, bloqueio_pin_ate = null
     where id = s.id;
    insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
    values (s.gerador_id, 'catador_cancelou', 'Procurando outro catador',
            'O catador cancelou; estamos buscando outro.', jsonb_build_object('solicitacao_id', s.id, 'motivo', v_motivo));
    if v_parada.id is not null then
      perform public._apos_remocao_parada(v_parada.rota_id);
    end if;
    perform public.gerar_proxima_oferta(s.id);
  end if;
end;
$$;

-- ---------- trocar_ponto_destino (CAT, UC07) ----------
create function public.trocar_ponto_destino(p_rota uuid, p_ponto uuid) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  r public.rotas;
  p public.pontos_coleta%rowtype;
begin
  if v_uid is null or public.papel_atual() is distinct from 'catador' then
    raise exception 'sem_permissao';
  end if;
  r := public._travar_rota(p_rota);
  if r.id is null or r.catador_id <> v_uid then
    raise exception 'rota_inexistente';
  end if;
  if r.status not in ('planejada','em_andamento') then
    raise exception 'rota_invalida';
  end if;
  select * into p from public.pontos_coleta where id = p_ponto and ativo;
  if not found then
    raise exception 'ponto_inexistente';
  end if;
  if exists (select 1 from public.rota_paradas where rota_id = r.id and tipo = 'descarte' and status = 'no_local') then
    raise exception 'rota_invalida';
  end if;
  update public.rota_paradas set ponto_id = p.id, localizacao = p.localizacao
   where rota_id = r.id and tipo = 'descarte' and status in ('pendente','a_caminho');
  -- versao + 1 sinaliza o recalculo (planejar-rota, T4.2); a polyline atual fica obsoleta ate la
  update public.rotas set ponto_destino_id = p.id, versao = versao + 1 where id = r.id;
end;
$$;

-- ---------- avaliar (GER/CAT, UC13, RN12) ----------
create function public.avaliar(p_solicitacao uuid, p_nota int, p_comentario text default null) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_comentario text := nullif(btrim(p_comentario), '');
  s public.solicitacoes%rowtype;
  v_avaliado uuid;
begin
  if v_uid is null or coalesce(public.papel_atual()::text, '') not in ('gerador','catador') then
    raise exception 'sem_permissao';
  end if;
  if p_nota is null or p_nota not between 1 and 5 or length(coalesce(v_comentario, '')) > 500 then
    raise exception 'parametro_invalido';
  end if;
  select * into s from public.solicitacoes where id = p_solicitacao;
  if not found or (s.gerador_id <> v_uid and s.catador_id is distinct from v_uid) then
    raise exception 'solicitacao_inexistente';
  end if;
  if s.status not in ('coletada','entregue') or s.catador_id is null then      -- RN12: so apos a coleta
    raise exception 'avaliacao_indisponivel';
  end if;
  v_avaliado := case when v_uid = s.gerador_id then s.catador_id else s.gerador_id end;

  begin
    insert into public.avaliacoes (solicitacao_id, avaliador_id, avaliado_id, nota, comentario)
    values (s.id, v_uid, v_avaliado, p_nota, v_comentario);
  exception when unique_violation then
    raise exception 'avaliacao_duplicada';
  end;

  -- media recalculada a partir das avaliacoes (exata; o lock da linha do avaliado serializa concorrentes)
  if v_avaliado = s.catador_id then
    perform 1 from public.catadores where perfil_id = v_avaliado for update;
    update public.catadores c
       set avaliacao_media = x.media, total_avaliacoes = x.total
      from (select round(avg(nota), 2) as media, count(*)::int as total
              from public.avaliacoes where avaliado_id = v_avaliado) x
     where c.perfil_id = v_avaliado;
  else
    perform 1 from public.geradores where perfil_id = v_avaliado for update;
    update public.geradores g
       set avaliacao_media = x.media, total_avaliacoes = x.total
      from (select round(avg(nota), 2) as media, count(*)::int as total
              from public.avaliacoes where avaliado_id = v_avaliado) x
     where g.perfil_id = v_avaliado;
  end if;
end;
$$;

-- ---------- resetar_demo (ADM, UC15) ----------
-- Apaga o movimento operacional e restaura o estado dos catadores gravado pelo seed (demo_estado_catadores).
-- Nao mexe em usuarios, perfis, enderecos, pontos, precos nem parametros.
create function public.resetar_demo() returns void
language plpgsql
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

  delete from public.entregas where true;                  -- cascata: entrega_itens
  delete from public.rotas where true;                     -- cascata: rota_paradas
  delete from public.solicitacoes where true;              -- cascata: ofertas, avaliacoes, eventos, materiais, posicoes
  delete from public.notificacoes where true;
  delete from public.localizacoes_catador where true;

  update public.catadores set avaliacao_media = 0, total_avaliacoes = 0;
  update public.geradores set avaliacao_media = 0, total_avaliacoes = 0;
  update public.catadores c
     set situacao = b.situacao, localizacao_atual = b.localizacao_atual,
         localizacao_atualizada_em = b.localizacao_atualizada_em
    from public.demo_estado_catadores b
   where b.catador_id = c.perfil_id;
  update public.catadores set situacao = 'disponivel'
   where situacao = 'em_rota' and perfil_id not in (select catador_id from public.demo_estado_catadores);
end;
$$;

-- ---------- P-009: gerar_proxima_oferta com raios padrao (mesma assinatura) ----------
create or replace function public.gerar_proxima_oferta(p_solicitacao uuid) returns uuid
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
  v_raios jsonb;
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
  -- P-009: parametro ausente ou invalido cai no padrao RN02
  select coalesce((select valor from public.parametros
                    where chave = 'raios_busca_m' and jsonb_typeof(valor) = 'array' and jsonb_array_length(valor) > 0),
                  '[3000,5000,8000]'::jsonb) into v_raios;

  if s.tentativas_oferta < v_max then
    v_lat := st_y(s.localizacao::geometry);
    v_lng := st_x(s.localizacao::geometry);
    select coalesce(array_agg(o.catador_id), '{}') into v_excl from public.ofertas o where o.solicitacao_id = s.id;

    for v_raio in
      select (r #>> '{}')::int from jsonb_array_elements(v_raios) r order by (r #>> '{}')::int
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

-- ---------- P-009: criar_solicitacao com limites, foto https, PIN criptografico (mesma assinatura) ----------
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
              and status in ('buscando','aceita','a_caminho','no_local','coletada')) then
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

-- ---------- grants ----------
revoke all on function
  public.alternar_disponibilidade(boolean),
  public.atualizar_localizacao(float8, float8, uuid),
  public.iniciar_rota(uuid),
  public.avancar_parada(uuid, text, text, text),
  public.registrar_entrega(uuid, jsonb),
  public.cancelar_solicitacao(uuid, text),
  public.trocar_ponto_destino(uuid, uuid),
  public.avaliar(uuid, int, text),
  public.resetar_demo()
  from public, anon;
grant execute on function
  public.alternar_disponibilidade(boolean),
  public.atualizar_localizacao(float8, float8, uuid),
  public.iniciar_rota(uuid),
  public.avancar_parada(uuid, text, text, text),
  public.registrar_entrega(uuid, jsonb),
  public.cancelar_solicitacao(uuid, text),
  public.trocar_ponto_destino(uuid, uuid),
  public.avaliar(uuid, int, text),
  public.resetar_demo()
  to authenticated;
revoke all on function public.gerar_proxima_oferta(uuid) from public, anon, authenticated;
