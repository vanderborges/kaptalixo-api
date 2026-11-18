-- T1.9: ETA da coleta visivel ao gerador dono.
-- v_solicitacao_gerador ganha (no fim, sem mexer nas colunas existentes) `eta` e `distancia_trecho_m`
-- da parada de COLETA da propria solicitacao, enquanto ela esta ativa com catador (aceita/a_caminho/no_local)
-- e a parada ainda nao foi concluida/pulada. Nada de outras paradas ou geradores: o join e por solicitacao_id.
-- Em buscando/coletada/entregue/cancelada/sem_catador os campos ficam nulos. Continua 1 linha por solicitacao.
create or replace view public.v_solicitacao_gerador with (security_barrier = true) as
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
            then extensions.st_x(c.localizacao_atual::extensions.geometry) end as catador_lng,
       pp.eta as eta,
       pp.distancia_trecho_m as distancia_trecho_m
  from public.solicitacoes s
  left join public.perfis pc on pc.id = s.catador_id
  left join public.catadores c on c.perfil_id = s.catador_id
  left join lateral (
        select p.eta, p.distancia_trecho_m
          from public.rota_paradas p
         where p.solicitacao_id = s.id
           and p.tipo = 'coleta'
           and p.status in ('pendente','a_caminho','no_local')
           and s.status in ('aceita','a_caminho','no_local')
         order by p.ordem
         limit 1
       ) pp on true
 where s.gerador_id = auth.uid();

revoke all on public.v_solicitacao_gerador from public, anon;
grant select on public.v_solicitacao_gerador to authenticated;
