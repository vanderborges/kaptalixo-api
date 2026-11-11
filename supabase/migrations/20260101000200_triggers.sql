-- T1.1: triggers de atualizado_em e de auditoria de status das solicitacoes.

-- Atualiza atualizado_em em qualquer update. Nao precisa de security definer.
create function public.tg_atualizado_em() returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

-- Grava eventos_solicitacao a cada insert/mudanca de status. security definer porque
-- o chamador (authenticated) nao tem grant direto na tabela de auditoria.
-- ator_id = auth.uid() somente se existir em perfis (FK); caso contrario null
-- (ex.: jobs, service_role).
create function public.tg_solicitacao_evento() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ator uuid;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  select p.id into v_ator from public.perfis p where p.id = auth.uid();

  insert into public.eventos_solicitacao (solicitacao_id, de_status, para_status, ator_id)
  values (
    new.id,
    case when tg_op = 'UPDATE' then old.status else null end,
    new.status,
    v_ator
  );
  return new;
end;
$$;

revoke execute on function public.tg_atualizado_em() from public, anon, authenticated;
revoke execute on function public.tg_solicitacao_evento() from public, anon, authenticated;

create trigger trg_solicitacao_atualizado_em
  before update on public.solicitacoes
  for each row execute function public.tg_atualizado_em();

create trigger trg_solicitacao_evento
  after insert or update of status on public.solicitacoes
  for each row execute function public.tg_solicitacao_evento();
