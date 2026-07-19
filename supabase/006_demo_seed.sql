-- ============================================================
-- 006_demo_seed.sql -- deixa o hub de demonstracao "cheio" e neutro
-- Cole no SQL Editor do Supabase e clique em Run. Idempotente.
--
-- O que faz:
--   1) Renomeia o cliente de exemplo (ex-PierCar) pra um nome neutro
--      que serve pra qualquer nicho, conecta o Instagram e o plano.
--   2) Popula o funil do CRM desse cliente com 12 leads (todas as
--      etapas), pra demo nao abrir vazia quando voce entra no hub dele.
--
-- Nao mexe nos outros workspaces nem nos leads da agencia (em-digital),
-- que ja vem populados pelo schema.sql.
-- ============================================================

-- 1) Cliente de exemplo neutro (serve pra estetica, academia, clinica, loja...)
update public.workspaces
   set name        = 'Bella Estética',
       slug        = 'bella-estetica',
       instagram   = 'bella.estetica',
       plan        = 'Plano completo',
       brand_color = '#FF7A29',
       status      = 'active'
 where slug = 'piercar';

-- 2) Funil do CRM desse cliente (mesmos leads neutros do fallback do hub.html)
insert into public.leads (workspace_id, name, interest, value, source, stage)
select w.id, x.name, x.interest, x.value, x.source, x.stage
from public.workspaces w,
(values
  ('Marcos Vinícius',  'Combo Premium',     890, 'Instagram', 0),
  ('Patrícia Rocha',   'Plano Anual',      1200, 'Meta Ads',  0),
  ('Fernanda Melo',    'Plano Mensal',      490, 'Instagram', 0),
  ('Juliana Prado',    'Pacote Completo',  1500, 'WhatsApp',  1),
  ('Antônio Lima',     'Sessão Avulsa',     350, 'Site',      1),
  ('Bruno Castro',     'Pacote Completo',  1800, 'WhatsApp',  1),
  ('Carla Souza',      'Plano Trimestral',  690, 'Meta Ads',  2),
  ('Rafael Dias',      'Consultoria',      1200, 'Instagram', 2),
  ('Beatriz Nunes',    'Combo Premium',     890, 'WhatsApp',  3),
  ('Diego Alves',      'Pacote Anual',     2200, 'Site',      3),
  ('Sr. Eduardo',      'Projeto Completo', 2400, 'Indicação', 4),
  ('Larissa Pinto',    'Plano Mensal',      490, 'Site',      4)
) as x(name, interest, value, source, stage)
where w.slug = 'bella-estetica'
  and not exists (select 1 from public.leads l where l.workspace_id = w.id);
