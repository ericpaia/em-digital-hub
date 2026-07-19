-- ============================================================
-- 008_instagram_feed.sql -- guarda o token do Instagram por workspace
-- Cole no SQL Editor do Supabase e clique em Run. Idempotente.
--
-- A tabela NAO tem policy de RLS de proposito: so a Edge Function
-- (service role) le/escreve. O navegador nunca ve o token.
--
-- Depois de rodar isto, rode o INSERT do token (arquivo/instrucao
-- separada) com o token que voce gerou no painel da Meta.
-- ============================================================

create table if not exists public.ig_connections (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  username     text,
  access_token text not null,
  expires_at   timestamptz,
  updated_at   timestamptz not null default now()
);

alter table public.ig_connections enable row level security;
-- sem create policy = ninguem no navegador acessa; so o service role da funcao.
