-- T1.1: parametros de negocio (docs/05 secao 6). Configuracao, nao dado de demo.
insert into public.parametros (chave, valor, descricao) values
  ('raios_busca_m',               '[3000,5000,8000]'::jsonb,       'RN02: raios de busca de catadores (m)'),
  ('oferta_validade_s',           '45'::jsonb,                     'RN03: validade da oferta (s)'),
  ('max_ofertas_por_solicitacao', '5'::jsonb,                      'RN03: maximo de ofertas por solicitacao'),
  ('desvio_max_rota_m',           '1500'::jsonb,                   'RN05: desvio maximo para oferta a catador em rota (m)'),
  ('custo_km_reais',              '0.90'::jsonb,                   'RN06: custo por km (R$)'),
  ('peso_saco_kg',                '{"P":2,"M":5,"G":10}'::jsonb,   'RN07: peso estimado por tamanho de saco (kg)'),
  ('pin_max_erros',               '3'::jsonb,                      'UC08: erros de PIN antes do bloqueio'),
  ('pin_bloqueio_s',              '120'::jsonb,                    'UC08: duracao do bloqueio de PIN (s)'),
  ('raio_chegada_m',              '80'::jsonb,                     'UC08: raio para marcar chegada (m)'),
  ('intervalo_loc_rota_s',        '5'::jsonb,                      'UC08: intervalo de envio de posicao em rota (s)'),
  ('intervalo_loc_disp_s',        '30'::jsonb,                     'UC14: intervalo de envio de posicao disponivel (s)'),
  ('modo_demo',                   'true'::jsonb,                   'Habilita resetar_demo');
