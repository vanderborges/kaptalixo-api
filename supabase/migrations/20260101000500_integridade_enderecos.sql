-- T1.2: impede IDOR de endereco. Um endereco so pode ser referenciado por quem o possui:
-- FKs compostas (endereco, dono) em geradores.endereco_padrao_id e solicitacoes.endereco_id.
-- MATCH SIMPLE: com a coluna do endereco nula a FK nao e checada (ON DELETE SET NULL preserva o resto).

alter table public.enderecos
  add constraint enderecos_id_perfil_uk unique (id, perfil_id);

alter table public.geradores drop constraint geradores_endereco_padrao_id_fkey;
alter table public.geradores
  add constraint geradores_endereco_do_dono_fk
  foreign key (endereco_padrao_id, perfil_id)
  references public.enderecos (id, perfil_id)
  on delete set null (endereco_padrao_id);

alter table public.solicitacoes drop constraint solicitacoes_endereco_id_fkey;
alter table public.solicitacoes
  add constraint solicitacoes_endereco_do_gerador_fk
  foreign key (endereco_id, gerador_id)
  references public.enderecos (id, perfil_id)
  on delete set null (endereco_id);
