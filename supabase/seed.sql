-- T1.3: seed de demonstracao (docs/05 secao 8). SO PARA DESENVOLVIMENTO LOCAL.
-- Credenciais fixas de dev (senha abaixo) nunca devem ser usadas fora da POC.
-- Roda como postgres no `supabase db reset`, depois das migrations.
set search_path = public, extensions;

-- ============ CONSTANTES (troque aqui para mudar de cidade) ============
create temp table seed_cfg as
select -23.5505::float8 as lat,        -- CIDADE_DEMO_LAT
       -46.6333::float8 as lng,        -- CIDADE_DEMO_LNG
       'Sao Paulo'::text as cidade,
       'SP'::char(2)     as uf,
       'Kaptalixo#Dev1'::text as senha_dev;

-- Ponto a (dx metros leste, dy metros norte) do centro da cidade demo.
create function pg_temp.pt(dx float8, dy float8) returns geography
language sql stable as $$
  select st_setsrid(st_makepoint(
           c.lng + degrees(dx / (6371000 * cos(radians(c.lat)))),
           c.lat + degrees(dy / 6371000)), 4326)::geography
  from seed_cfg c
$$;

-- UUID deterministico: prefixo (tipo) + indice.
create function pg_temp.uid(prefixo text, n int) returns uuid
language sql immutable as $$
  select (prefixo || '-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

-- Cria usuario no Auth local (email confirmado) + identidade.
create function pg_temp.criar_usuario(p_id uuid, p_email text, p_nome text) returns void
language plpgsql as $$
declare v_senha text;
begin
  select senha_dev into v_senha from seed_cfg;
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated',
    p_email, crypt(v_senha, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('nome', p_nome), now(), now(), '', '', '', ''
  );
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), p_id, p_id::text,
          jsonb_build_object('sub', p_id::text, 'email', p_email, 'email_verified', true),
          'email', now(), now(), now());
end;
$$;

-- ============ MATERIAIS (7) ============
insert into materiais (id, codigo, nome, categoria, cor_ui) values
  (1, 'papel',         'Papel',         'papel',   '#4A90D9'),
  (2, 'papelao',       'Papelao',       'papel',   '#B08850'),
  (3, 'pet',           'PET',           'plastico','#2EAE5B'),
  (4, 'plastico_duro', 'Plastico duro', 'plastico','#E8A317'),
  (5, 'vidro',         'Vidro',         'vidro',   '#1ABC9C'),
  (6, 'aluminio',      'Aluminio',      'metal',   '#95A5A6'),
  (7, 'ferro',         'Ferro',         'metal',   '#7F4F3A');

-- ============ USUARIOS / PERFIS ============
-- Admin (1): admin@kaptalixo.dev
select pg_temp.criar_usuario(pg_temp.uid('a0000000', 1), 'admin@kaptalixo.dev', 'Administrador Demo');
insert into perfis (id, papel, nome, telefone) values
  (pg_temp.uid('a0000000', 1), 'admin', 'Administrador Demo', '11990000000');

-- Operadores de ponto (4): ponto1..ponto4@kaptalixo.dev
select pg_temp.criar_usuario(pg_temp.uid('b0000000', n), 'ponto' || n || '@kaptalixo.dev', 'Operador Ponto ' || n)
from generate_series(1, 4) n;
insert into perfis (id, papel, nome, telefone)
select pg_temp.uid('b0000000', n), 'ponto', 'Operador Ponto ' || n, '1190000010' || n
from generate_series(1, 4) n;

-- Geradores (5): gerador1..gerador5@kaptalixo.dev
select pg_temp.criar_usuario(pg_temp.uid('c0000000', n), 'gerador' || n || '@kaptalixo.dev', g.nome)
from (values (1,'Ana Souza'),(2,'Bruno Lima'),(3,'Carla Dias'),(4,'Diego Ramos'),(5,'Elisa Prado')) g(n, nome);
insert into perfis (id, papel, nome, telefone)
select pg_temp.uid('c0000000', n), 'gerador', nome, '1190000020' || n
from (values (1,'Ana Souza'),(2,'Bruno Lima'),(3,'Carla Dias'),(4,'Diego Ramos'),(5,'Elisa Prado')) g(n, nome);

insert into enderecos (id, perfil_id, apelido, logradouro, numero, bairro, cidade, uf, cep, localizacao)
select pg_temp.uid('d0000000', g.n), pg_temp.uid('c0000000', g.n), 'Casa', g.rua, g.num, g.bairro,
       c.cidade, c.uf, '01000-00' || g.n, pg_temp.pt(g.dx, g.dy)
from seed_cfg c,
     (values (1,'Rua das Flores','120','Centro',   -800.0,  600.0),
             (2,'Av. Brasil',    '455','Jardim Sul', 1200.0, -900.0),
             (3,'Rua do Sol',     '78','Vila Norte', 300.0, 2100.0),
             (4,'Rua Verde',     '310','Bela Vista',-2300.0, -400.0),
             (5,'Alameda Azul',   '12','Parque Leste',3200.0, 1500.0)) g(n, rua, num, bairro, dx, dy);

insert into geradores (perfil_id, endereco_padrao_id)
select pg_temp.uid('c0000000', n), pg_temp.uid('d0000000', n) from generate_series(1, 5) n;

-- Catadores (8 aprovados + 1 pendente): catador1..catador9@kaptalixo.dev
-- 1-5 pessoas, 6-8 empresas, 9 pendente (pessoa). 4 disponiveis, 4 offline, capacidades 6-40.
select pg_temp.criar_usuario(pg_temp.uid('e0000000', n), 'catador' || n || '@kaptalixo.dev', k.nome)
from (values (1,'Joao Catador'),(2,'Maria Reciclagem'),(3,'Pedro Carrinho'),(4,'Lucia Bike'),(5,'Marcos Moto'),
             (6,'EcoColeta Ltda'),(7,'Verde Vivo ME'),(8,'Recicla Sul Coop'),(9,'Roberto Novo')) k(n, nome);
insert into perfis (id, papel, nome, telefone)
select pg_temp.uid('e0000000', n), 'catador', nome, '1190000030' || n
from (values (1,'Joao Catador'),(2,'Maria Reciclagem'),(3,'Pedro Carrinho'),(4,'Lucia Bike'),(5,'Marcos Moto'),
             (6,'EcoColeta Ltda'),(7,'Verde Vivo ME'),(8,'Recicla Sul Coop'),(9,'Roberto Novo')) k(n, nome);

insert into catadores (perfil_id, tipo, documento, razao_social, status_cadastro, tipo_veiculo,
                       capacidade_sacos, situacao, localizacao_atual, localizacao_atualizada_em)
select pg_temp.uid('e0000000', k.n), k.tipo::tipo_catador, k.doc, k.razao, k.status::status_cadastro, k.veiculo,
       k.cap, k.sit::disponibilidade, pg_temp.pt(k.dx, k.dy), now()
from (values
  (1,'pessoa', '111.111.111-11', null,                  'aprovado','carrinho',    6,'disponivel',  -500.0,  400.0),
  (2,'pessoa', '222.222.222-22', null,                  'aprovado','bicicleta',   8,'disponivel',   900.0, -600.0),
  (3,'pessoa', '333.333.333-33', null,                  'aprovado','carrinho',   10,'offline',      200.0, 1800.0),
  (4,'pessoa', '444.444.444-44', null,                  'aprovado','bicicleta',  12,'disponivel', -1900.0, -200.0),
  (5,'pessoa', '555.555.555-55', null,                  'aprovado','moto',       15,'offline',     2800.0, 1200.0),
  (6,'empresa','11.111.111/0001-11','EcoColeta Ltda',   'aprovado','utilitario', 40,'disponivel',  1500.0,  300.0),
  (7,'empresa','22.222.222/0001-22','Verde Vivo ME',    'aprovado','utilitario', 30,'offline',    -3000.0, 2500.0),
  (8,'empresa','33.333.333/0001-33','Recicla Sul Coop', 'aprovado','caminhonete',25,'disponivel',  -300.0,-2200.0),
  (9,'pessoa', '999.999.999-99', null,                  'pendente','carrinho',    8,'offline',     600.0,  900.0)
) k(n, tipo, doc, razao, status, veiculo, cap, sit, dx, dy);

-- ============ PONTOS DE COLETA (4) + precos + horarios ============
-- Ponto 4 fecha as 18h (fechado a noite); os demais tem horarios diferentes.
insert into pontos_coleta (id, perfil_id, nome, logradouro, numero, bairro, cidade, uf, telefone, localizacao, horario_funcionamento)
select pg_temp.uid('f0000000', p.n), pg_temp.uid('b0000000', p.n), p.nome, p.rua, p.num, p.bairro,
       c.cidade, c.uf, '1130000' || p.n, pg_temp.pt(p.dx, p.dy), p.horario::jsonb
from seed_cfg c,
     (values
  (1,'Ferro-Velho Central',  'Rua da Sucata', '10','Centro',     0.0,  -300.0,
     '{"seg":[["07:00","22:00"]],"ter":[["07:00","22:00"]],"qua":[["07:00","22:00"]],"qui":[["07:00","22:00"]],"sex":[["07:00","22:00"]],"sab":[["07:00","20:00"]]}'),
  (2,'Cooperativa Recicla+', 'Av. Cooperativa','500','Jardim Sul', 1800.0, -1200.0,
     '{"seg":[["08:00","17:00"]],"ter":[["08:00","17:00"]],"qua":[["08:00","17:00"]],"qui":[["08:00","17:00"]],"sex":[["08:00","17:00"]]}'),
  (3,'Deposito Vila Norte',  'Rua do Deposito','88','Vila Norte', 400.0, 2600.0,
     '{"seg":[["06:00","23:00"]],"ter":[["06:00","23:00"]],"qua":[["06:00","23:00"]],"qui":[["06:00","23:00"]],"sex":[["06:00","23:00"]],"sab":[["06:00","23:00"]],"dom":[["08:00","14:00"]]}'),
  (4,'Papelao do Leste',     'Rua Leste',     '300','Parque Leste',-2600.0, 900.0,
     '{"seg":[["08:00","18:00"]],"ter":[["08:00","18:00"]],"qua":[["08:00","18:00"]],"qui":[["08:00","18:00"]],"sex":[["08:00","18:00"]],"sab":[["08:00","12:00"]]}')
     ) p(n, nome, rua, num, bairro, dx, dy, horario);

-- Precos por kg (R$) levemente diferentes entre pontos (material 1..7).
insert into ponto_precos (ponto_id, material_id, preco_kg)
select pg_temp.uid('f0000000', p.n), m.id, round((m.base * p.fator)::numeric, 2)
from (values (1, 1.00), (2, 1.12), (3, 0.95), (4, 1.05)) p(n, fator)
join (values (1::smallint, 0.30), (2::smallint, 0.45), (3::smallint, 1.60), (4::smallint, 0.90),
             (5::smallint, 0.15), (6::smallint, 5.50), (7::smallint, 0.55)) m(id, base) on true;

-- Ponto 3 paga mais por aluminio e ponto 4 mais por papelao (diferenca clara para o UC07).
update ponto_precos set preco_kg = 6.20 where ponto_id = pg_temp.uid('f0000000', 3) and material_id = 6;
update ponto_precos set preco_kg = 0.70 where ponto_id = pg_temp.uid('f0000000', 4) and material_id = 2;

-- ============ PARAMETROS ============
-- Ja carregados pela migration (inclui modo_demo); aqui apenas garante o modo demo ligado.
insert into parametros (chave, valor, descricao)
values ('modo_demo', 'true'::jsonb, 'Habilita resetar_demo')
on conflict (chave) do update set valor = 'true'::jsonb;
