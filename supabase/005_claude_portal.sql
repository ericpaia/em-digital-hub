-- ============================================================
-- 005_claude_portal.sql — link do portal do Claude (claude.ai) por cliente
-- Cole no SQL Editor do Supabase e clique em "Run". Idempotente.
-- A aba "Claude" do hub abre esse link (a conta/assento do cliente no
-- claude.ai, com as skills/contexto instalados). Sem API, sem custo.
-- ============================================================

alter table public.workspaces add column if not exists claude_url text;
