-- T1.2: views seguras. Sao views "definer" (padrao do Postgres: rodam como o dono, que ignora RLS)
-- de proposito: expoem so as colunas permitidas e filtram a linha por auth.uid() dentro da propria
-- view. Nenhuma devolve dados de outro usuario; anon nao tem grant.
-- Coordenadas saem como lat/lng (double) para o app; geography nao e exposta.

-- Oferta pendente do catador: SEM pin, SEM endereco exato, SEM observacao/foto.
-- Localizacao so aproximada (grade de 0,01 grau, ~1 km) e bairro; exata so em v_solicitacao_catador apos o aceite.
create view public.v_oferta_resumo as
select o.id as oferta_id,
       o.solicitacao_id,
       o.status,
       o.ordem,
       o.distancia_m,
       o.eta_s,
       o.na_rota,
       o.enviada_em,
       o.expira_em,
       s.qtd_sacos,
       s.tamanho,
       s.peso_estimado_kg,
       s.agendada_para,
       array(select sm.material_id from public.solicitacao_materiais sm
              where sm.solicitacao_id = s.id order by sm.material_id) as materiais,
       e.bairro,
       extensions.st_y(extensions.st_snaptogrid(s.localizacao::extensions.geometry, 0.01)) as aprox_lat,
       extensions.st_x(extensions.st_snaptogrid(s.localizacao::extensions.geometry, 0.01)) as aprox_lng
  from public.ofertas o
  join public.solicitacoes s on s.id = o.solicitacao_id
  left join public.enderecos e on e.id = s.endereco_id
 where o.catador_id = auth.uid()
   and o.status = 'pendente';

-- Solicitacao atribuida ao catador (apos o aceite): endereco exato, SEM pin_coleta.
create view public.v_solicitacao_catador as
select s.id,
       s.status,
       s.catador_id,
       s.qtd_sacos,
       s.tamanho,
       s.peso_estimado_kg,
       s.observacao,
       s.foto_url,
       s.agendada_para,
       s.endereco_texto,
       extensions.st_y(s.localizacao::extensions.geometry) as lat,
       extensions.st_x(s.localizacao::extensions.geometry) as lng,
       s.bloqueio_pin_ate,
       s.criado_em,
       s.atualizado_em,
       array(select sm.material_id from public.solicitacao_materiais sm
              where sm.solicitacao_id = s.id order by sm.material_id) as materiais,
       pg.nome as gerador_nome,
       pg.avatar_url as gerador_avatar_url
  from public.solicitacoes s
  join public.perfis pg on pg.id = s.gerador_id
 where s.catador_id = auth.uid();

-- Solicitacao do gerador dono: inclui pin_coleta e dados do catador que atende
-- (nome, avatar, nota, veiculo e posicao enquanto a coleta esta ativa).
create view public.v_solicitacao_gerador as
select s.id,
       s.status,
       s.gerador_id,
       s.endereco_id,
       s.endereco_texto,
       extensions.st_y(s.localizacao::extensions.geometry) as lat,
       extensions.st_x(s.localizacao::extensions.geometry) as lng,
       s.qtd_sacos,
       s.tamanho,
       s.peso_estimado_kg,
       s.observacao,
       s.foto_url,
       s.agendada_para,
       s.pin_coleta,
       s.tentativas_oferta,
       s.motivo_cancelamento,
       s.catador_id,
       s.criado_em,
       s.atualizado_em,
       array(select sm.material_id from public.solicitacao_materiais sm
              where sm.solicitacao_id = s.id order by sm.material_id) as materiais,
       pc.nome as catador_nome,
       pc.avatar_url as catador_avatar_url,
       c.tipo_veiculo as catador_tipo_veiculo,
       c.avaliacao_media as catador_avaliacao_media,
       case when s.status in ('aceita','a_caminho','no_local','coletada')
            then extensions.st_y(c.localizacao_atual::extensions.geometry) end as catador_lat,
       case when s.status in ('aceita','a_caminho','no_local','coletada')
            then extensions.st_x(c.localizacao_atual::extensions.geometry) end as catador_lng
  from public.solicitacoes s
  left join public.perfis pc on pc.id = s.catador_id
  left join public.catadores c on c.perfil_id = s.catador_id
 where s.gerador_id = auth.uid();

-- Rota do catador dono, com polyline (a tabela rotas nao concede polyline a ninguem).
create view public.v_rota_catador as
select r.id, r.catador_id, r.status, r.ponto_destino_id, r.alternativas_ponto,
       r.distancia_total_m, r.duracao_total_s, r.polyline, r.origem_calculo, r.versao,
       r.criado_em, r.iniciada_em, r.concluida_em
  from public.rotas r
 where r.catador_id = auth.uid();

-- Dados completos do catador (inclui documento e razao_social): o proprio ou admin.
create view public.v_catador_privado as
select c.*
  from public.catadores c
 where c.perfil_id = auth.uid() or public.e_admin();

revoke all on public.v_oferta_resumo, public.v_solicitacao_catador, public.v_solicitacao_gerador,
  public.v_rota_catador, public.v_catador_privado from public, anon;
grant select on public.v_oferta_resumo, public.v_solicitacao_catador, public.v_solicitacao_gerador,
  public.v_rota_catador, public.v_catador_privado to authenticated;
