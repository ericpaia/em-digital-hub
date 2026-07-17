-- ============================================================
-- 002_instagram.sql — adiciona o @ do Instagram em cada workspace
-- Cole no SQL Editor do Supabase e clique em "Run". É idempotente
-- (pode rodar de novo sem problema).
-- ============================================================

alter table public.workspaces add column if not exists instagram text;

-- @ inicial de alguns workspaces (só preenche se ainda estiver vazio).
-- Depois dá pra trocar direto pela interface do hub, na aba Instagram > Perfil.
update public.workspaces set instagram = 'piercar.multimarcas' where slug = 'piercar'    and instagram is null;
update public.workspaces set instagram = 'emdigital'           where slug = 'em-digital' and instagram is null;
