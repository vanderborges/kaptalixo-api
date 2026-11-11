-- T1.1: enums e tabelas base (derivado de db/referencia/schema.sql).
-- PostGIS vive no schema extensions; o search_path abaixo resolve geography e gist.
-- RLS, grants, triggers, Realtime e parametros vem nas migrations seguintes.
set search_path = public, extensions;

-- ---------- ENUMS ----------
create type papel_usuario        as enum ('gerador','catador','ponto','admin');
create type tipo_catador         as enum ('pessoa','empresa');
create type status_cadastro      as enum ('pendente','aprovado','suspenso');
create type disponibilidade      as enum ('offline','disponivel','em_rota');
create type tamanho_saco         as enum ('P','M','G');
create type status_solicitacao   as enum ('buscando','aceita','a_caminho','no_local','coletada','entregue','cancelada','sem_catador');
create type status_oferta        as enum ('pendente','aceita','recusada','expirada','cancelada');
create type status_rota          as enum ('planejada','em_andamento','concluida','cancelada');
create type tipo_parada          as enum ('coleta','descarte');
create type status_parada        as enum ('pendente','a_caminho','no_local','concluida','pulada');
create type origem_calculo       as enum ('osrm','haversine');

-- ---------- IDENTIDADE ----------
create table perfis (
  id          uuid primary key references auth.users(id) on delete cascade,
  papel       papel_usuario not null,
  nome        text not null,
  telefone    text,
  avatar_url  text,
  criado_em   timestamptz not null default now()
);

create table enderecos (
  id           uuid primary key default gen_random_uuid(),
  perfil_id    uuid not null references perfis(id) on delete cascade,
  apelido      text,
  logradouro   text not null,
  numero       text,
  complemento  text,
  bairro       text,
  cidade       text not null,
  uf           char(2) not null,
  cep          text,
  referencia   text,
  localizacao  geography(Point,4326) not null,
  criado_em    timestamptz not null default now()
);
create index enderecos_perfil_idx on enderecos(perfil_id);
create index enderecos_loc_gix    on enderecos using gist(localizacao);

create table geradores (
  perfil_id          uuid primary key references perfis(id) on delete cascade,
  endereco_padrao_id uuid references enderecos(id) on delete set null,
  avaliacao_media    numeric(3,2) not null default 0,
  total_avaliacoes   int not null default 0
);

create table catadores (
  perfil_id                uuid primary key references perfis(id) on delete cascade,
  tipo                     tipo_catador not null default 'pessoa',
  documento                text,                  -- CPF/CNPJ (apenas texto na POC)
  razao_social             text,
  status_cadastro          status_cadastro not null default 'pendente',
  tipo_veiculo             text,                  -- carrinho, bicicleta, moto, utilitario...
  capacidade_sacos         int not null default 10 check (capacidade_sacos > 0),
  situacao                 disponibilidade not null default 'offline',
  localizacao_atual        geography(Point,4326),
  localizacao_atualizada_em timestamptz,
  avaliacao_media          numeric(3,2) not null default 0,
  total_avaliacoes         int not null default 0
);
create index catadores_disp_gix on catadores using gist(localizacao_atual)
  where situacao in ('disponivel','em_rota');

-- ---------- PONTOS E MATERIAIS ----------
create table materiais (
  id        smallint primary key,
  codigo    text not null unique,     -- papel, papelao, pet, plastico_duro, vidro, aluminio, ferro
  nome      text not null,
  categoria text not null,            -- papel | plastico | vidro | metal
  cor_ui    text
);

create table pontos_coleta (
  id                 uuid primary key default gen_random_uuid(),
  perfil_id          uuid references perfis(id) on delete set null,   -- operador do ponto
  nome               text not null,
  logradouro         text not null,
  numero             text,
  bairro             text,
  cidade             text not null,
  uf                 char(2) not null,
  telefone           text,
  localizacao        geography(Point,4326) not null,
  -- {"seg":[["08:00","17:00"]],"ter":[...],...}; dia ausente = fechado
  horario_funcionamento jsonb not null default '{}'::jsonb,
  ativo              boolean not null default true,
  criado_em          timestamptz not null default now()
);
create index pontos_loc_gix on pontos_coleta using gist(localizacao);

create table ponto_precos (
  ponto_id       uuid not null references pontos_coleta(id) on delete cascade,
  material_id    smallint not null references materiais(id),
  preco_kg       numeric(10,2) not null check (preco_kg >= 0),
  vigente_desde  timestamptz not null default now(),
  primary key (ponto_id, material_id)
);

-- ---------- SOLICITACOES ----------
create table solicitacoes (
  id               uuid primary key default gen_random_uuid(),
  gerador_id       uuid not null references geradores(perfil_id),
  endereco_id      uuid references enderecos(id) on delete set null,
  localizacao      geography(Point,4326) not null,        -- snapshot do local da coleta
  endereco_texto   text,
  qtd_sacos        int not null check (qtd_sacos between 1 and 20),
  tamanho          tamanho_saco not null default 'M',
  peso_estimado_kg numeric(8,2),
  observacao       text,
  foto_url         text,
  agendada_para    timestamptz,                           -- null = agora
  status           status_solicitacao not null default 'buscando',
  pin_coleta       char(4) not null,
  catador_id       uuid references catadores(perfil_id),
  tentativas_oferta int not null default 0,
  pin_erros        int not null default 0,
  bloqueio_pin_ate timestamptz,
  motivo_cancelamento text,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);
create index solic_status_idx   on solicitacoes(status);
create index solic_gerador_idx  on solicitacoes(gerador_id);
create index solic_catador_idx  on solicitacoes(catador_id);
create index solic_loc_gix      on solicitacoes using gist(localizacao);
-- no maximo 1 solicitacao ativa por gerador (UC03)
create unique index solic_uma_ativa_por_gerador on solicitacoes(gerador_id)
  where status in ('buscando','aceita','a_caminho','no_local','coletada');

create table solicitacao_materiais (
  solicitacao_id uuid not null references solicitacoes(id) on delete cascade,
  material_id    smallint not null references materiais(id),
  primary key (solicitacao_id, material_id)
);

create table eventos_solicitacao (
  id             bigserial primary key,
  solicitacao_id uuid not null references solicitacoes(id) on delete cascade,
  de_status      status_solicitacao,
  para_status    status_solicitacao not null,
  ator_id        uuid references perfis(id),
  detalhe        jsonb,
  criado_em      timestamptz not null default now()
);
create index eventos_solic_idx on eventos_solicitacao(solicitacao_id, criado_em);

-- ---------- OFERTAS ----------
create table ofertas (
  id             uuid primary key default gen_random_uuid(),
  solicitacao_id uuid not null references solicitacoes(id) on delete cascade,
  catador_id     uuid not null references catadores(perfil_id),
  ordem          int not null,
  status         status_oferta not null default 'pendente',
  distancia_m    int,
  eta_s          int,
  na_rota        boolean not null default false,     -- oferta extra a catador em rota (UC10)
  enviada_em     timestamptz not null default now(),
  expira_em      timestamptz not null,
  respondida_em  timestamptz,
  unique (solicitacao_id, catador_id)                 -- nunca oferta duas vezes ao mesmo catador
);
create index ofertas_catador_pend_idx on ofertas(catador_id) where status = 'pendente';
create index ofertas_expira_idx       on ofertas(expira_em)  where status = 'pendente';
create unique index ofertas_uma_pendente_por_solic on ofertas(solicitacao_id) where status = 'pendente';

-- ---------- ROTAS ----------
create table rotas (
  id               uuid primary key default gen_random_uuid(),
  catador_id       uuid not null references catadores(perfil_id),
  status           status_rota not null default 'planejada',
  ponto_destino_id uuid references pontos_coleta(id),
  alternativas_ponto jsonb,                            -- [{ponto_id, score}, ...]
  distancia_total_m int,
  duracao_total_s   int,
  polyline         text,                               -- polyline codificada (precision 5)
  origem_calculo   origem_calculo not null default 'osrm',
  versao           int not null default 1,
  criado_em        timestamptz not null default now(),
  iniciada_em      timestamptz,
  concluida_em     timestamptz
);
-- no maximo 1 rota aberta por catador
create unique index rotas_uma_aberta_por_catador on rotas(catador_id)
  where status in ('planejada','em_andamento');

create table rota_paradas (
  id             uuid primary key default gen_random_uuid(),
  rota_id        uuid not null references rotas(id) on delete cascade,
  ordem          int not null,
  tipo           tipo_parada not null,
  solicitacao_id uuid references solicitacoes(id),
  ponto_id       uuid references pontos_coleta(id),
  localizacao    geography(Point,4326) not null,
  status         status_parada not null default 'pendente',
  eta            timestamptz,
  distancia_trecho_m int,
  duracao_trecho_s   int,
  chegou_em      timestamptz,
  concluida_em   timestamptz,
  check ((tipo = 'coleta'  and solicitacao_id is not null and ponto_id is null) or
         (tipo = 'descarte' and ponto_id is not null and solicitacao_id is null))
);
create index paradas_rota_idx on rota_paradas(rota_id, ordem);
create index paradas_solic_idx on rota_paradas(solicitacao_id);

-- ---------- ENTREGA / VENDA ----------
create table entregas (
  id            uuid primary key default gen_random_uuid(),
  rota_id       uuid not null unique references rotas(id),
  ponto_id      uuid not null references pontos_coleta(id),
  catador_id    uuid not null references catadores(perfil_id),
  peso_total_kg numeric(10,2) not null default 0,
  valor_total   numeric(12,2) not null default 0,
  registrada_por uuid references perfis(id),
  criado_em     timestamptz not null default now()
);

create table entrega_itens (
  id          uuid primary key default gen_random_uuid(),
  entrega_id  uuid not null references entregas(id) on delete cascade,
  material_id smallint not null references materiais(id),
  peso_kg     numeric(10,2) not null check (peso_kg > 0),
  preco_kg    numeric(10,2) not null,
  valor       numeric(12,2) not null
);
create index entrega_itens_idx on entrega_itens(entrega_id);

-- ---------- QUALIDADE / SUPORTE ----------
create table avaliacoes (
  id             uuid primary key default gen_random_uuid(),
  solicitacao_id uuid not null references solicitacoes(id) on delete cascade,
  avaliador_id   uuid not null references perfis(id),
  avaliado_id    uuid not null references perfis(id),
  nota           smallint not null check (nota between 1 and 5),
  comentario     text,
  criado_em      timestamptz not null default now(),
  unique (solicitacao_id, avaliador_id),
  check (avaliador_id <> avaliado_id)
);

create table notificacoes (
  id         uuid primary key default gen_random_uuid(),
  perfil_id  uuid not null references perfis(id) on delete cascade,
  tipo       text not null,
  titulo     text not null,
  corpo      text,
  dados      jsonb,
  lida       boolean not null default false,
  criado_em  timestamptz not null default now()
);
create index notif_perfil_idx on notificacoes(perfil_id, lida, criado_em desc);

create table localizacoes_catador (
  id          bigserial primary key,
  catador_id  uuid not null references catadores(perfil_id) on delete cascade,
  rota_id     uuid references rotas(id) on delete set null,
  localizacao geography(Point,4326) not null,
  registrada_em timestamptz not null default now()
);
create index loc_catador_idx on localizacoes_catador(catador_id, registrada_em desc);

create table parametros (
  chave      text primary key,
  valor      jsonb not null,
  descricao  text
);
