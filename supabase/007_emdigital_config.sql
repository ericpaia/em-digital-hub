-- ============================================================
-- 007_emdigital_config.sql -- configura o hub da propria EM Digital
-- Cole no SQL Editor do Supabase e clique em Run. Idempotente.
--
--   1) Adiciona a coluna site_url nos workspaces (aba "Meu site" passa
--      a mostrar/abrir o site real de cada cliente, nao mais o mockup).
--   2) Conecta o Instagram e o site da EM Digital (workspace agencia).
-- ============================================================

alter table public.workspaces add column if not exists site_url text;

update public.workspaces
   set instagram = 'emdigital_agencia',
       site_url  = 'https://emdigitalagencia.lovable.app/'
 where slug = 'em-digital';
