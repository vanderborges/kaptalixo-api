-- T1.2: funcoes auxiliares, grants minimos (por coluna onde ha dado sensivel) e policies RLS.
-- Principios:
--  * anon nao recebe nada. authenticated recebe so o necessario; escrita sensivel e por RPC.
--  * pin_coleta, pin_erros, bloqueio_pin_ate (solicitacoes), documento e razao_social (catadores),
--    polyline/alternativas_ponto (rotas) e distancia_m/eta_s (ofertas) ficam FORA do grant de SELECT.
--    O Realtime so entrega colunas com has_column_privilege, entao a publicacao tambem fica sem esses
--    campos. Quem precisa deles le pelas views da migration seguinte.
--  * Helpers abaixo sao security definer (leem tabelas sem disparar RLS) para evitar recursao entre policies.
--  * Nas policies os helpers vao em (select ...) para virarem initPlan (avaliados uma vez por consulta).

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

-- o usuario e o catador dono de uma rota ainda aberta? (paradas de rota encerrada nao ficam com o catador)
create function public.catador_da_rota_aberta(p_rota uuid) returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.rotas r
        where r.id = p_rota and r.catador_id = auth.uid() and r.status in ('planejada','em_andamento')) $$;

-- o usuario e gerador de alguma solicitacao com parada na rota?
create function public.gerador_na_rota(p_rota uuid) returns boolean
language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.rota_paradas rp join public.solicitacoes s on s.id = rp.solicitacao_id
   where rp.rota_id = p_rota and s.gerador_id = auth.uid()) $$;

revoke all on function public.papel_atual(), public.e_admin(), public.opera_ponto(uuid),
  public.catador_da_rota_aberta(uuid), public.gerador_na_rota(uuid)
  from public, anon;
grant execute on function public.papel_atual(), public.e_admin(), public.opera_ponto(uuid),
  public.catador_da_rota_aberta(uuid), public.gerador_na_rota(uuid)
  to authenticated;

-- ---------- guardas por trigger ----------
-- Grant por coluna nao distingue linha nem papel: o catador edita a propria linha e o operador o proprio
-- ponto, entao triggers garantem o resto (auth.uid() nulo = service_role/jobs).
--  * catadores: so admin muda status_cadastro; apos sair de 'pendente', documento/razao_social/tipo
--    so mudam pelo admin (senao uma conta aprovada trocaria de titular sem nova analise).
create function public.tg_catador_protege() returns trigger
language plpgsql
set search_path = public
as $$
begin
  if auth.uid() is null or public.e_admin() then
    return new;
  end if;
  if new.status_cadastro is distinct from old.status_cadastro then
    raise exception 'status_cadastro: somente admin';
  end if;
  if old.status_cadastro <> 'pendente'
     and (new.documento is distinct from old.documento
          or new.razao_social is distinct from old.razao_social
          or new.tipo is distinct from old.tipo) then
    raise exception 'cadastro aprovado: alteracao somente por admin';
  end if;
  return new;
end;
$$;
--  * pontos_coleta: operador nao move o ponto, nao o (des)ativa e nao troca o operador.
create function public.tg_ponto_protege() returns trigger
language plpgsql
set search_path = public
as $$
begin
  if auth.uid() is null or public.e_admin() then
    return new;
  end if;
  if new.localizacao::text is distinct from old.localizacao::text
     or new.ativo is distinct from old.ativo
     or new.perfil_id is distinct from old.perfil_id then
    raise exception 'ponto: localizacao, ativo e operador somente por admin';
  end if;
  return new;
end;
$$;
revoke all on function public.tg_catador_protege(), public.tg_ponto_protege() from public, anon, authenticated;
create trigger trg_catador_protege
  before update on public.catadores
  for each row execute function public.tg_catador_protege();
create trigger trg_ponto_protege
  before update on public.pontos_coleta
  for each row execute function public.tg_ponto_protege();

-- ---------- indices para os predicados das policies ----------
create index rotas_ponto_destino_idx on public.rotas(ponto_destino_id);
create index entregas_catador_idx    on public.entregas(catador_id);
create index entregas_ponto_idx      on public.entregas(ponto_id);
create index avaliacoes_avaliador_idx on public.avaliacoes(avaliador_id);
create index avaliacoes_avaliado_idx  on public.avaliacoes(avaliado_id);
create index pontos_perfil_idx       on public.pontos_coleta(perfil_id);

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
-- UPDATE sem id/criado_em; localizacao/ativo/perfil_id so admin (trigger tg_ponto_protege)
grant select, insert, delete on public.pontos_coleta to authenticated;
grant update (perfil_id, nome, logradouro, numero, bairro, cidade, uf, telefone, localizacao,
              horario_funcionamento, ativo)
  on public.pontos_coleta to authenticated;
grant select, insert, delete on public.ponto_precos to authenticated;
grant update (preco_kg, vigente_desde) on public.ponto_precos to authenticated;

-- sem pin_coleta, pin_erros, bloqueio_pin_ate
grant select (id, gerador_id, endereco_id, localizacao, endereco_texto, qtd_sacos, tamanho,
              peso_estimado_kg, observacao, foto_url, agendada_para, status, catador_id,
              tentativas_oferta, motivo_cancelamento, criado_em, atualizado_em)
  on public.solicitacoes to authenticated;

grant select on public.solicitacao_materiais, public.eventos_solicitacao to authenticated;
-- sem distancia_m/eta_s exatos (trilateracao do endereco antes do aceite): o catador usa v_oferta_resumo (arredondado)
grant select (id, solicitacao_id, catador_id, ordem, status, na_rota, enviada_em, expira_em, respondida_em)
  on public.ofertas to authenticated;

-- sem polyline/alternativas_ponto (revelariam paradas de outros geradores): catador usa v_rota_catador
grant select (id, catador_id, status, ponto_destino_id, distancia_total_m, duracao_total_s,
              origem_calculo, versao, criado_em, iniciada_em, concluida_em)
  on public.rotas to authenticated;
grant select on public.rota_paradas, public.entregas, public.entrega_itens, public.avaliacoes to authenticated;

grant select on public.notificacoes to authenticated;
grant update (lida) on public.notificacoes to authenticated;

-- historico de posicoes: so o proprio catador e admin. O gerador recebe so a posicao atual,
-- pela v_solicitacao_gerador, enquanto a coleta esta aceita/a_caminho/no_local.
grant select on public.localizacoes_catador to authenticated;

-- ---------- policies ----------
-- perfis: so o proprio e admin. Nome/avatar da contraparte chegam pelas views (sem telefone).
create policy perfis_select on public.perfis for select to authenticated
  using (id = (select auth.uid()) or (select public.e_admin()));
create policy perfis_insert on public.perfis for insert to authenticated
  with check (id = (select auth.uid()) and papel in ('gerador','catador'));
create policy perfis_update on public.perfis for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy enderecos_select on public.enderecos for select to authenticated
  using (perfil_id = (select auth.uid()) or (select public.e_admin()));
create policy enderecos_insert on public.enderecos for insert to authenticated
  with check (perfil_id = (select auth.uid()));
create policy enderecos_update on public.enderecos for update to authenticated
  using (perfil_id = (select auth.uid())) with check (perfil_id = (select auth.uid()));
create policy enderecos_delete on public.enderecos for delete to authenticated
  using (perfil_id = (select auth.uid()));

create policy geradores_select on public.geradores for select to authenticated
  using (perfil_id = (select auth.uid()) or (select public.e_admin()));
create policy geradores_insert on public.geradores for insert to authenticated
  with check (perfil_id = (select auth.uid()) and (select public.papel_atual()) = 'gerador');
create policy geradores_update on public.geradores for update to authenticated
  using (perfil_id = (select auth.uid())) with check (perfil_id = (select auth.uid()));

create policy catadores_select on public.catadores for select to authenticated
  using (perfil_id = (select auth.uid()) or (select public.e_admin()));
create policy catadores_insert on public.catadores for insert to authenticated
  with check (perfil_id = (select auth.uid()) and (select public.papel_atual()) = 'catador');
create policy catadores_update on public.catadores for update to authenticated
  using (perfil_id = (select auth.uid()) or (select public.e_admin()))
  with check (perfil_id = (select auth.uid()) or (select public.e_admin()));

-- catalogo e parametros: leitura para autenticados, escrita admin
create policy materiais_select on public.materiais for select to authenticated using (true);
create policy materiais_admin  on public.materiais for all to authenticated
  using ((select public.e_admin())) with check ((select public.e_admin()));
create policy parametros_select on public.parametros for select to authenticated using (true);
create policy parametros_admin  on public.parametros for all to authenticated
  using ((select public.e_admin())) with check ((select public.e_admin()));

create policy pontos_select on public.pontos_coleta for select to authenticated using (true);
create policy pontos_insert on public.pontos_coleta for insert to authenticated
  with check ((select public.e_admin()));
create policy pontos_update on public.pontos_coleta for update to authenticated
  using (perfil_id = (select auth.uid()) or (select public.e_admin()))
  with check (perfil_id = (select auth.uid()) or (select public.e_admin()));
create policy pontos_delete on public.pontos_coleta for delete to authenticated
  using ((select public.e_admin()));

create policy precos_select on public.ponto_precos for select to authenticated using (true);
create policy precos_escrita on public.ponto_precos for all to authenticated
  using (public.opera_ponto(ponto_id) or (select public.e_admin()))
  with check (public.opera_ponto(ponto_id) or (select public.e_admin()));

-- solicitacoes: gerador dono, admin, e o catador ATRIBUIDO apenas enquanto a coleta esta ativa
-- (aceita/a_caminho/no_local): depois disso (coletada/entregue/cancelada) ele perde endereco, observacao e foto.
-- Catador com oferta apenas pendente NAO tem policy aqui: ve so v_oferta_resumo (sem endereco exato).
create policy solic_select on public.solicitacoes for select to authenticated
  using (gerador_id = (select auth.uid())
         or (catador_id = (select auth.uid()) and status in ('aceita','a_caminho','no_local'))
         or (select public.e_admin()));

create policy solic_mat_select on public.solicitacao_materiais for select to authenticated
  using (exists (select 1 from public.solicitacoes s where s.id = solicitacao_id));  -- herda a RLS de solicitacoes

create policy eventos_select on public.eventos_solicitacao for select to authenticated
  using ((select public.e_admin()) or exists (
    select 1 from public.solicitacoes s where s.id = solicitacao_id and s.gerador_id = (select auth.uid())));

-- ofertas: so o catador destinatario e admin (o gerador acompanha pela contagem em solicitacoes.tentativas_oferta)
create policy ofertas_select on public.ofertas for select to authenticated
  using (catador_id = (select auth.uid()) or (select public.e_admin()));

create policy rotas_select on public.rotas for select to authenticated
  using (catador_id = (select auth.uid()) or public.gerador_na_rota(id)
         or public.opera_ponto(ponto_destino_id) or (select public.e_admin()));

-- catador: paradas de rota aberta; gerador: apenas a parada da propria solicitacao;
-- operador de ponto: apenas a parada de descarte no seu ponto
create policy paradas_select on public.rota_paradas for select to authenticated
  using (public.catador_da_rota_aberta(rota_id) or public.opera_ponto(ponto_id) or (select public.e_admin())
         or exists (select 1 from public.solicitacoes s
                     where s.id = solicitacao_id and s.gerador_id = (select auth.uid())));

create policy entregas_select on public.entregas for select to authenticated
  using (catador_id = (select auth.uid()) or public.opera_ponto(ponto_id) or (select public.e_admin()));
create policy entrega_itens_select on public.entrega_itens for select to authenticated
  using (exists (select 1 from public.entregas e where e.id = entrega_id));  -- herda a RLS de entregas

create policy avaliacoes_select on public.avaliacoes for select to authenticated
  using (avaliador_id = (select auth.uid()) or avaliado_id = (select auth.uid()) or (select public.e_admin()));

create policy notif_select on public.notificacoes for select to authenticated
  using (perfil_id = (select auth.uid()));
create policy notif_update on public.notificacoes for update to authenticated
  using (perfil_id = (select auth.uid())) with check (perfil_id = (select auth.uid()));

create policy loc_select on public.localizacoes_catador for select to authenticated
  using (catador_id = (select auth.uid()) or (select public.e_admin()));
