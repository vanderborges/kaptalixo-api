-- T1.2: funcoes auxiliares, grants minimos (por coluna onde ha dado sensivel) e policies RLS.
-- Principios:
--  * anon nao recebe nada. authenticated recebe so o necessario; escrita sensivel e por RPC.
--  * pin_coleta, pin_erros, bloqueio_pin_ate (solicitacoes), documento e razao_social (catadores)
--    e polyline/alternativas_ponto (rotas) ficam FORA do grant de SELECT. O Realtime so entrega
--    colunas com has_column_privilege, entao a publicacao tambem fica sem esses campos.
--    Quem precisa deles le pelas views da migration seguinte.
--  * Helpers abaixo sao security definer (leem tabelas sem disparar RLS) para evitar recursao entre policies.

-- ---------- helpers ----------
create function public.papel_atual() returns public.papel_usuario
language sql stable security definer set search_path = public
as $$ select p.papel from public.perfis p where p.id = auth.uid() $$;

create function public.e_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select coalesce((select p.papel = 'admin' from public.perfis p where p.id = auth.uid()), false) $$;

-- o usuario opera o ponto?
create function public.opera_ponto(p_ponto uuid) returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.pontos_coleta pc where pc.id = p_ponto and pc.perfil_id = auth.uid()) $$;

-- o usuario e o catador dono da rota?
create function public.e_catador_da_rota(p_rota uuid) returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.rotas r where r.id = p_rota and r.catador_id = auth.uid()) $$;

-- o usuario e gerador de alguma solicitacao com parada na rota?
create function public.gerador_na_rota(p_rota uuid) returns boolean
language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.rota_paradas rp join public.solicitacoes s on s.id = rp.solicitacao_id
   where rp.rota_id = p_rota and s.gerador_id = auth.uid()) $$;

revoke all on function public.papel_atual(), public.e_admin(), public.opera_ponto(uuid),
  public.e_catador_da_rota(uuid), public.gerador_na_rota(uuid)
  from public, anon;
grant execute on function public.papel_atual(), public.e_admin(), public.opera_ponto(uuid),
  public.e_catador_da_rota(uuid), public.gerador_na_rota(uuid)
  to authenticated;

-- ---------- guarda de status_cadastro ----------
-- Grant por coluna nao distingue linha: o catador pode editar a propria linha, entao o trigger
-- garante que so admin muda status_cadastro (auth.uid() nulo = service_role/jobs).
create function public.tg_catador_protege_status() returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status_cadastro is distinct from old.status_cadastro
     and auth.uid() is not null and not public.e_admin() then
    raise exception 'status_cadastro: somente admin';
  end if;
  return new;
end;
$$;
revoke all on function public.tg_catador_protege_status() from public, anon, authenticated;
create trigger trg_catador_protege_status
  before update of status_cadastro on public.catadores
  for each row execute function public.tg_catador_protege_status();

-- ---------- grants (tabelas) ----------
grant usage on schema public to authenticated;

grant select on public.perfis to authenticated;
grant insert (id, papel, nome, telefone, avatar_url) on public.perfis to authenticated;
grant update (nome, telefone, avatar_url) on public.perfis to authenticated;

grant select on public.enderecos to authenticated;
grant insert (perfil_id, apelido, logradouro, numero, complemento, bairro, cidade, uf, cep, referencia, localizacao)
  on public.enderecos to authenticated;
grant update (apelido, logradouro, numero, complemento, bairro, cidade, uf, cep, referencia, localizacao)
  on public.enderecos to authenticated;
grant delete on public.enderecos to authenticated;

grant select on public.geradores to authenticated;
grant insert (perfil_id, endereco_padrao_id) on public.geradores to authenticated;
grant update (endereco_padrao_id) on public.geradores to authenticated;

-- sem documento/razao_social (LGPD): o dono e o admin leem por v_catador_privado
grant select (perfil_id, tipo, status_cadastro, tipo_veiculo, capacidade_sacos, situacao,
              localizacao_atual, localizacao_atualizada_em, avaliacao_media, total_avaliacoes)
  on public.catadores to authenticated;
grant insert (perfil_id, tipo, documento, razao_social, tipo_veiculo, capacidade_sacos)
  on public.catadores to authenticated;
grant update (tipo, documento, razao_social, tipo_veiculo, capacidade_sacos, status_cadastro)
  on public.catadores to authenticated;

grant select, insert, update, delete on public.materiais, public.parametros to authenticated;
grant select, insert, update, delete on public.pontos_coleta to authenticated;
grant select, insert, update, delete on public.ponto_precos to authenticated;

-- sem pin_coleta, pin_erros, bloqueio_pin_ate
grant select (id, gerador_id, endereco_id, localizacao, endereco_texto, qtd_sacos, tamanho,
              peso_estimado_kg, observacao, foto_url, agendada_para, status, catador_id,
              tentativas_oferta, motivo_cancelamento, criado_em, atualizado_em)
  on public.solicitacoes to authenticated;

grant select on public.solicitacao_materiais, public.eventos_solicitacao, public.ofertas to authenticated;

-- sem polyline/alternativas_ponto (revelariam paradas de outros geradores): catador usa v_rota_catador
grant select (id, catador_id, status, ponto_destino_id, distancia_total_m, duracao_total_s,
              origem_calculo, versao, criado_em, iniciada_em, concluida_em)
  on public.rotas to authenticated;
grant select on public.rota_paradas, public.entregas, public.entrega_itens, public.avaliacoes to authenticated;

grant select on public.notificacoes to authenticated;
grant update (lida) on public.notificacoes to authenticated;

grant select on public.localizacoes_catador to authenticated;

-- ---------- policies ----------
-- perfis: so o proprio e admin. Nome/avatar da contraparte chegam pelas views (sem telefone).
create policy perfis_select on public.perfis for select to authenticated
  using (id = (select auth.uid()) or public.e_admin());
create policy perfis_insert on public.perfis for insert to authenticated
  with check (id = (select auth.uid()) and papel in ('gerador','catador'));
create policy perfis_update on public.perfis for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy enderecos_select on public.enderecos for select to authenticated
  using (perfil_id = (select auth.uid()) or public.e_admin());
create policy enderecos_insert on public.enderecos for insert to authenticated
  with check (perfil_id = (select auth.uid()));
create policy enderecos_update on public.enderecos for update to authenticated
  using (perfil_id = (select auth.uid())) with check (perfil_id = (select auth.uid()));
create policy enderecos_delete on public.enderecos for delete to authenticated
  using (perfil_id = (select auth.uid()));

create policy geradores_select on public.geradores for select to authenticated
  using (perfil_id = (select auth.uid()) or public.e_admin());
create policy geradores_insert on public.geradores for insert to authenticated
  with check (perfil_id = (select auth.uid()) and public.papel_atual() = 'gerador');
create policy geradores_update on public.geradores for update to authenticated
  using (perfil_id = (select auth.uid())) with check (perfil_id = (select auth.uid()));

create policy catadores_select on public.catadores for select to authenticated
  using (perfil_id = (select auth.uid()) or public.e_admin());
create policy catadores_insert on public.catadores for insert to authenticated
  with check (perfil_id = (select auth.uid()) and public.papel_atual() = 'catador');
create policy catadores_update on public.catadores for update to authenticated
  using (perfil_id = (select auth.uid()) or public.e_admin())
  with check (perfil_id = (select auth.uid()) or public.e_admin());

-- catalogo e parametros: leitura para autenticados, escrita admin
create policy materiais_select on public.materiais for select to authenticated using (true);
create policy materiais_admin  on public.materiais for all to authenticated
  using (public.e_admin()) with check (public.e_admin());
create policy parametros_select on public.parametros for select to authenticated using (true);
create policy parametros_admin  on public.parametros for all to authenticated
  using (public.e_admin()) with check (public.e_admin());

create policy pontos_select on public.pontos_coleta for select to authenticated using (true);
create policy pontos_insert on public.pontos_coleta for insert to authenticated
  with check (public.e_admin());
create policy pontos_update on public.pontos_coleta for update to authenticated
  using (perfil_id = (select auth.uid()) or public.e_admin())
  with check (perfil_id = (select auth.uid()) or public.e_admin());
create policy pontos_delete on public.pontos_coleta for delete to authenticated
  using (public.e_admin());

create policy precos_select on public.ponto_precos for select to authenticated using (true);
create policy precos_escrita on public.ponto_precos for all to authenticated
  using (public.opera_ponto(ponto_id) or public.e_admin())
  with check (public.opera_ponto(ponto_id) or public.e_admin());

-- solicitacoes: gerador dono, catador ATRIBUIDO (catador_id so e preenchido no aceite) e admin.
-- Catador com oferta apenas pendente NAO tem policy aqui: ve so v_oferta_resumo (sem endereco exato).
create policy solic_select on public.solicitacoes for select to authenticated
  using (gerador_id = (select auth.uid()) or catador_id = (select auth.uid()) or public.e_admin());

create policy solic_mat_select on public.solicitacao_materiais for select to authenticated
  using (exists (select 1 from public.solicitacoes s where s.id = solicitacao_id));  -- herda a RLS de solicitacoes

create policy eventos_select on public.eventos_solicitacao for select to authenticated
  using (public.e_admin() or exists (
    select 1 from public.solicitacoes s where s.id = solicitacao_id and s.gerador_id = (select auth.uid())));

-- ofertas: so o catador destinatario e admin (o gerador acompanha pela contagem em solicitacoes.tentativas_oferta)
create policy ofertas_select on public.ofertas for select to authenticated
  using (catador_id = (select auth.uid()) or public.e_admin());

create policy rotas_select on public.rotas for select to authenticated
  using (catador_id = (select auth.uid()) or public.gerador_na_rota(id)
         or public.opera_ponto(ponto_destino_id) or public.e_admin());

-- gerador ve apenas a parada da propria solicitacao; operador de ponto, apenas a parada de descarte no seu ponto
create policy paradas_select on public.rota_paradas for select to authenticated
  using (public.e_catador_da_rota(rota_id) or public.opera_ponto(ponto_id) or public.e_admin()
         or exists (select 1 from public.solicitacoes s
                     where s.id = solicitacao_id and s.gerador_id = (select auth.uid())));

create policy entregas_select on public.entregas for select to authenticated
  using (catador_id = (select auth.uid()) or public.opera_ponto(ponto_id) or public.e_admin());
create policy entrega_itens_select on public.entrega_itens for select to authenticated
  using (exists (select 1 from public.entregas e where e.id = entrega_id));  -- herda a RLS de entregas

create policy avaliacoes_select on public.avaliacoes for select to authenticated
  using (avaliador_id = (select auth.uid()) or avaliado_id = (select auth.uid()) or public.e_admin());

create policy notif_select on public.notificacoes for select to authenticated
  using (perfil_id = (select auth.uid()));
create policy notif_update on public.notificacoes for update to authenticated
  using (perfil_id = (select auth.uid())) with check (perfil_id = (select auth.uid()));

create policy loc_select on public.localizacoes_catador for select to authenticated
  using (catador_id = (select auth.uid()) or public.e_admin()
         or exists (select 1 from public.solicitacoes s
                     where s.catador_id = localizacoes_catador.catador_id
                       and s.gerador_id = (select auth.uid())
                       and s.status in ('aceita','a_caminho','no_local','coletada')));
