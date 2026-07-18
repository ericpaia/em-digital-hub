-- ============================================================
-- 004_canva_oauth.sql — tabelas de OAuth/tokens do Canva + bucket
-- Cole no SQL Editor do Supabase e clique em "Run". Idempotente.
-- Os tokens e os estados do OAuth SÓ são acessados pela Edge Function
-- (service role). RLS ligada e SEM policy = o navegador não lê nada disso.
-- ============================================================

-- unique pra dar upsert nos modelos vindos do Canva (por design)
create unique index if not exists templates_ws_canva
  on public.templates(workspace_id, canva_design_id)
  where canva_design_id is not null;

-- tokens de acesso do Canva (1 por workspace)
create table if not exists public.canva_tokens (
  workspace_id  uuid primary key references public.workspaces(id) on delete cascade,
  access_token  text not null,
  refresh_token text,
  expires_at    timestamptz not null,
  updated_at    timestamptz not null default now()
);
alter table public.canva_tokens enable row level security;
-- (sem policy de propósito: só service role acessa)

-- estados temporários do fluxo OAuth (PKCE)
create table if not exists public.canva_oauth_states (
  state         text primary key,
  workspace_id  uuid not null references public.workspaces(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  code_verifier text not null,
  folder_id     text,
  folder_name   text,
  created_at    timestamptz not null default now()
);
alter table public.canva_oauth_states enable row level security;
-- (sem policy de propósito: só service role acessa)

-- bucket público para cachear os thumbnails do Canva (as URLs do Canva expiram)
insert into storage.buckets (id, name, public)
values ('canva-thumbs', 'canva-thumbs', true)
on conflict (id) do nothing;
