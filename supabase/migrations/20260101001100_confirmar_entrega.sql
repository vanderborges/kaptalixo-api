-- T1.7: confirmar_entrega (PON): entrega simplificada, sem itens/peso/valor (POC).
-- registrar_entrega continua existindo, inalterada.
set search_path = public, extensions;

create function public.confirmar_entrega(p_rota uuid) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_ponto uuid;
  r public.rotas;
  v_entrega uuid;
begin
  if v_uid is null or public.papel_atual() is distinct from 'ponto' then
    raise exception 'sem_permissao';
  end if;

  -- so o operador do ponto de destino da rota enxerga que ela existe
  select ponto_destino_id into v_ponto from public.rotas where id = p_rota;
  if not found or v_ponto is null or not public.opera_ponto(v_ponto) then
    raise exception 'rota_inexistente';
  end if;
  r := public._travar_rota(p_rota);
  -- rechecagem apos o lock (corrida com trocar_ponto_destino)
  if r.ponto_destino_id is null or not public.opera_ponto(r.ponto_destino_id) then
    raise exception 'rota_inexistente';
  end if;
  if r.status <> 'em_andamento' then
    raise exception 'rota_invalida';
  end if;
  if exists (select 1 from public.rota_paradas
              where rota_id = r.id and tipo = 'coleta' and status in ('pendente','a_caminho','no_local')) then
    raise exception 'coletas_pendentes';
  end if;
  if not exists (select 1 from public.rota_paradas
                  where rota_id = r.id and tipo = 'coleta' and status = 'concluida') then
    raise exception 'sem_coletas';
  end if;

  insert into public.entregas (rota_id, ponto_id, catador_id, registrada_por)
  values (r.id, r.ponto_destino_id, r.catador_id, v_uid)
  returning id into v_entrega;

  with up as (
    update public.solicitacoes set status = 'entregue'
     where status = 'coletada'
       and id in (select solicitacao_id from public.rota_paradas
                   where rota_id = r.id and tipo = 'coleta' and status = 'concluida')
    returning id, gerador_id
  )
  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  select gerador_id, 'coleta_entregue', 'Entrega confirmada', 'Seu material foi entregue ao ponto de coleta.',
         jsonb_build_object('solicitacao_id', id)
    from up;

  update public.rota_paradas set status = 'concluida', chegou_em = coalesce(chegou_em, now()), concluida_em = now()
   where rota_id = r.id and tipo = 'descarte' and status <> 'concluida';
  update public.rotas set status = 'concluida', concluida_em = now() where id = r.id;
  update public.catadores set situacao = 'disponivel' where perfil_id = r.catador_id and situacao = 'em_rota';

  insert into public.notificacoes (perfil_id, tipo, titulo, corpo, dados)
  values (r.catador_id, 'entrega_registrada', 'Entrega confirmada', 'O ponto confirmou o recebimento do material.',
          jsonb_build_object('entrega_id', v_entrega));
  return v_entrega;
end;
$$;

revoke all on function public.confirmar_entrega(uuid) from public, anon;
grant execute on function public.confirmar_entrega(uuid) to authenticated;
