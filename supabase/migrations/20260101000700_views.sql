-- T1.2: views seguras. Sao views "definer" (padrao do Postgres: rodam como o dono, que ignora RLS)
-- de proposito: expoem so as colunas permitidas e filtram a linha por auth.uid() dentro da propria
-- view. security_barrier impede que predicados do usuario sejam avaliados antes do filtro.
-- Nenhuma devolve dados de outro usuario; anon nao tem grant.
-- Coordenadas saem como lat/lng (double) para o app; geography nao e exposta.

-- Oferta pendente e nao vencida do catador: SEM pin, SEM endereco exato, SEM observacao/foto.
-- Localizacao so aproximada (grade de 0,01 grau, ~1 km) e bairro; exata so em v_solicitacao_catador apos o aceite.
-- distancia_m arredondada a 100 m e eta_s a 60 s (a tabela ofertas nao concede essas colunas ao catador),
-- para nao permitir trilateracao do endereco com varias ofertas.
create view public.v_oferta_resumo with (security_barrier = true) as
select o.id as oferta_id,
       o.solicitacao_id,
       o.status,
       o.ordem,
       (round(o.distancia_m / 100.0) * 100)::int as distancia_m,
       (round(o.eta_s / 60.0) * 60)::int as eta_s,
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
   and o.status = 'pendente'
   and o.expira_em > now();

-- Solicitacoes atribuidas ao catador. Endereco exato, coordenadas, observacao, foto e dados do gerador
-- so enquanto a coleta esta ativa (aceita/a_caminho/no_local); depois ficam nulos. SEM pin_coleta.
create view public.v_solicitacao_catador with (security_barrier = true) as
select s.id,
       s.status,
       s.catador_id,
       s.qtd_sacos,
       s.tamanho,
       s.peso_estimado_kg,
       s.agendada_para,
       s.bloqueio_pin_ate,
       s.criado_em,
       s.atualizado_em,
       array(select sm.material_id from public.solicitacao_materiais sm
              where sm.solicitacao_id = s.id order by sm.material_id) as materiais,
       case when s.status in ('aceita','a_caminho','no_local') then s.observacao end as observacao,
       case when s.status in ('aceita','a_caminho','no_local') then s.foto_url end as foto_url,
       case when s.status in ('aceita','a_caminho','no_local') then s.endereco_texto end as endereco_texto,
       case when s.status in ('aceita','a_caminho','no_local')
            then extensions.st_y(s.localizacao::extensions.geometry) end as lat,
       case when s.status in ('aceita','a_caminho','no_local')
            then extensions.st_x(s.localizacao::extensions.geometry) end as lng,
       case when s.status in ('aceita','a_caminho','no_local') then pg.nome end as gerador_nome,
       case when s.status in ('aceita','a_caminho','no_local') then pg.avatar_url end as gerador_avatar_url
  from public.solicitacoes s
  join public.perfis pg on pg.id = s.gerador_id
 where s.catador_id = auth.uid();

-- Solicitacao do gerador dono: inclui pin_coleta e dados do catador que atende
-- (nome, avatar, nota, veiculo e posicao ATUAL apenas em aceita/a_caminho/no_local; em coletada a
-- posicao some, pois o catador segue para a casa de outros geradores). Historico de posicoes nao e exposto.
-- Posicao em tempo real: o app faz polling desta view (localizacoes_catador/catadores nao sao publicadas ao gerador).
create view public.v_solicitacao_gerador with (security_barrier = true) as
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
       case when s.status in ('aceita','a_caminho','no_local')
            then extensions.st_y(c.localizacao_atual::extensions.geometry) end as catador_lat,
       case when s.status in ('aceita','a_caminho','no_local')
            then extensions.st_x(c.localizacao_atual::extensions.geometry) end as catador_lng
  from public.solicitacoes s
  left join public.perfis pc on pc.id = s.catador_id
  left join public.catadores c on c.perfil_id = s.catador_id
 where s.gerador_id = auth.uid();

-- Rota do catador dono, com polyline (a tabela rotas nao concede polyline a ninguem).
create view public.v_rota_catador with (security_barrier = true) as
select r.id, r.catador_id, r.status, r.ponto_destino_id, r.alternativas_ponto,
       r.distancia_total_m, r.duracao_total_s, r.polyline, r.origem_calculo, r.versao,
       r.criado_em, r.iniciada_em, r.concluida_em
  from public.rotas r
 where r.catador_id = auth.uid();

-- Dados completos do catador (inclui documento e razao_social): o proprio ou admin.
create view public.v_catador_privado with (security_barrier = true) as
select c.*
  from public.catadores c
 where c.perfil_id = auth.uid() or public.e_admin();

revoke all on public.v_oferta_resumo, public.v_solicitacao_catador, public.v_solicitacao_gerador,
  public.v_rota_catador, public.v_catador_privado from public, anon;
grant select on public.v_oferta_resumo, public.v_solicitacao_catador, public.v_solicitacao_gerador,
  public.v_rota_catador, public.v_catador_privado to authenticated;
