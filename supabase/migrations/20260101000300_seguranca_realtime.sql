-- T1.1: RLS ligado em todas as tabelas (sem policies = nega tudo a anon/authenticated;
-- as policies e grants minimos vem na T1.2), revogacao de grants e publicacao Realtime.

do $$
declare
  t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end;
$$;

-- Grants explicitos: anon/authenticated nao herdam nada. service_role e postgres mantem acesso.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

-- Objetos futuros criados pelo postgres (migrations) tambem nascem sem grant a anon/authenticated.
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;
-- O EXECUTE para PUBLIC e um default global (nao por schema): so some sem "in schema".
-- Afeta funcoes futuras criadas pelo postgres; cada RPC deve dar grant execute a authenticated.
alter default privileges for role postgres revoke execute on functions from public;

-- Realtime (a entrega de eventos ainda depende dos grants/policies da T1.2).
alter publication supabase_realtime add table
  public.solicitacoes, public.ofertas, public.rotas, public.rota_paradas,
  public.catadores, public.entregas, public.notificacoes;
