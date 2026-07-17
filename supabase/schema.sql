-- ============================================================
-- EM Digital Hub — schema inicial (Supabase / Postgres)
-- Cole tudo isto no SQL Editor do Supabase e clique em "Run".
-- Cria: workspaces (multi-tenant), membros, e as tabelas dos
-- módulos (CRM, Financeiro, Instagram, Agenda), com RLS
-- (cada workspace só enxerga o que é dele; o owner enxerga tudo).
-- ============================================================

-- ---------- perfis (1:1 com auth.users) ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  created_at timestamptz not null default now()
);

-- ---------- workspaces (a EM Digital + cada cliente) ----------
create table if not exists public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  kind        text not null default 'client' check (kind in ('agency','client')),
  brand_color text not null default '#FF7A29',
  plan        text,
  status      text not null default 'active',
  instagram   text,
  created_at  timestamptz not null default now()
);

-- ---------- quem acessa qual workspace ----------
create table if not exists public.memberships (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null default 'member' check (role in ('owner','admin','member')),
  created_at   timestamptz not null default now(),
  unique (workspace_id, user_id)
);

-- ---------- CRM: leads ----------
create table if not exists public.leads (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name         text not null,
  interest     text,               -- carro / serviço de interesse
  value        numeric default 0,
  source       text,               -- Instagram, WhatsApp, Site, Meta Ads...
  stage        int not null default 0,  -- 0 novo, 1 contato, 2 test drive, 3 proposta, 4 fechado
  created_at   timestamptz not null default now()
);

-- ---------- Financeiro: lançamentos ----------
create table if not exists public.fin_entries (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  kind         text not null check (kind in ('in','out')),
  description  text not null,
  category     text,
  amount       numeric not null default 0,
  entry_date   date not null default current_date,
  created_at   timestamptz not null default now()
);

-- ---------- Instagram: conteúdo ----------
create table if not exists public.ig_posts (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  kind         text not null default 'carrossel' check (kind in ('carrossel','post','story')),
  title        text,
  caption      text,
  model        text,
  status       text not null default 'rascunho', -- rascunho, aguardando, agendado, publicado
  scheduled_at timestamptz,
  created_at   timestamptz not null default now()
);

-- ---------- Agenda ----------
create table if not exists public.agenda_events (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  title        text not null,
  kind         text not null default 'tarefa', -- tarefa, marco, evento, vencimento
  starts_at    timestamptz not null,
  created_at   timestamptz not null default now()
);

-- ============================================================
-- Funções de acesso (security definer: ignoram RLS por dentro,
-- então não há recursão nas políticas)
-- ============================================================
create or replace function public.is_member(ws uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.memberships m
    where m.workspace_id = ws and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_agency()
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.memberships m
    join public.workspaces w on w.id = m.workspace_id
    where m.user_id = auth.uid() and w.kind = 'agency' and m.role = 'owner'
  );
$$;

-- ============================================================
-- RLS
-- ============================================================
alter table public.profiles      enable row level security;
alter table public.workspaces    enable row level security;
alter table public.memberships   enable row level security;
alter table public.leads         enable row level security;
alter table public.fin_entries   enable row level security;
alter table public.ig_posts      enable row level security;
alter table public.agenda_events enable row level security;

-- profiles: cada um vê o próprio; owner vê todos
drop policy if exists profiles_rw on public.profiles;
create policy profiles_rw on public.profiles
  using (id = auth.uid() or public.is_agency())
  with check (id = auth.uid() or public.is_agency());

-- workspaces: membro vê o seu; owner vê todos
drop policy if exists ws_read on public.workspaces;
create policy ws_read on public.workspaces
  for select using (public.is_member(id) or public.is_agency());
drop policy if exists ws_write on public.workspaces;
create policy ws_write on public.workspaces
  for all using (public.is_agency()) with check (public.is_agency());

-- memberships: cada um vê as próprias; owner gerencia todas
drop policy if exists mem_read on public.memberships;
create policy mem_read on public.memberships
  for select using (user_id = auth.uid() or public.is_agency());
drop policy if exists mem_write on public.memberships;
create policy mem_write on public.memberships
  for all using (public.is_agency()) with check (public.is_agency());

-- módulos: membro do workspace (ou owner) faz tudo dentro do workspace
do $$
declare t text;
begin
  foreach t in array array['leads','fin_entries','ig_posts','agenda_events'] loop
    execute format('drop policy if exists %I_rw on public.%I;', t, t);
    execute format(
      'create policy %I_rw on public.%I for all using (public.is_member(workspace_id) or public.is_agency()) with check (public.is_member(workspace_id) or public.is_agency());',
      t, t);
  end loop;
end $$;

-- ============================================================
-- Novo usuário: cria perfil e, se for o e-mail do owner,
-- vira dono do workspace da EM Digital automaticamente.
-- (troque o e-mail se quiser outro owner)
-- ============================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email))
  on conflict (id) do nothing;

  if new.email = 'ericminellio@gmail.com' then
    insert into public.memberships (workspace_id, user_id, role)
    select id, new.id, 'owner' from public.workspaces where slug = 'em-digital'
    on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- SEED — a EM Digital (agência) + os clientes + dados de preview
-- ============================================================
insert into public.workspaces (name, slug, kind, brand_color, plan, status) values
  ('EM Digital',          'em-digital',  'agency', '#22E07C', 'agência',       'active'),
  ('PierCar Multimarcas', 'piercar',     'client', '#FF7A29', 'Assento Team',  'active'),
  ('Ariza',               'ariza',       'client', '#5AA9F9', 'API Sonnet',    'active'),
  ('Odonto Max',          'odonto-max',  'client', '#22C55E', 'API Haiku',     'active'),
  ('Domínio 3 Dimensões', 'dominio-3d',  'client', '#B08CFF', 'API Sonnet',    'active'),
  ('Tuba Lyra',           'tuba-lyra',   'client', '#EAB308', 'API Haiku',     'active'),
  ('Nova Ótica',          'nova-otica',  'client', '#9CA3AF', 'Não conectado', 'setup')
on conflict (slug) do nothing;

-- ---- dados de preview da EM Digital (leads = clientes em potencial) ----
insert into public.leads (workspace_id, name, interest, value, source, stage)
select id, x.name, x.interest, x.value, x.source, x.stage
from public.workspaces w,
(values
  ('Barbearia do Zé',     'Hub completo',        5000, 'Instagram', 0),
  ('Studio Bella Estética','Hub + Instagram',    5000, 'Indicação', 0),
  ('Auto Peças Rondon',   'Hub + CRM',           5000, 'Site',      1),
  ('Clínica Vitta',       'Hub completo',        5000, 'WhatsApp',  1),
  ('Padaria Pão Nosso',   'Instagram',           5000, 'Meta Ads',  2),
  ('Advocacia Menezes',   'Hub + Financeiro',    5000, 'Indicação', 3),
  ('Pet Shop Amigo Fiel', 'Hub completo',        5000, 'Instagram', 4),
  ('Academia Corpo Ativo','Hub + CRM',           5000, 'Site',      4)
) as x(name, interest, value, source, stage)
where w.slug = 'em-digital'
and not exists (select 1 from public.leads l where l.workspace_id = w.id);

-- ---- financeiro da EM Digital ----
insert into public.fin_entries (workspace_id, kind, description, category, amount, entry_date)
select id, x.kind, x.description, x.category, x.amount, x.entry_date
from public.workspaces w,
(values
  ('in',  'Instalação — Pet Shop Amigo Fiel', 'Instalação',  5000, current_date - 3),
  ('in',  'Instalação — Academia Corpo Ativo','Instalação',  5000, current_date - 10),
  ('in',  'Mensalidade — 5 clientes',          'Recorrente',  1500, current_date - 1),
  ('out', 'Assinatura Claude (assento + API)', 'Ferramentas',  431, current_date - 2),
  ('out', 'VPS + domínios',                    'Infra',        180, current_date - 5),
  ('out', 'Anúncios (captação)',               'Marketing',    600, current_date - 6)
) as x(kind, description, category, amount, entry_date)
where w.slug = 'em-digital'
and not exists (select 1 from public.fin_entries f where f.workspace_id = w.id);

-- ---- instagram da EM Digital ----
insert into public.ig_posts (workspace_id, kind, title, caption, model, status)
select id, x.kind, x.title, x.caption, x.model, x.status
from public.workspaces w,
(values
  ('carrossel','Como um hub aumenta suas vendas','3 formas de vender mais com um hub próprio','institucional','publicado'),
  ('post',     'Antes e depois de um cliente',   'Veja o resultado da Pet Shop Amigo Fiel','depoimento','agendado'),
  ('story',    'Bastidores da instalação',       'Montando um hub em tempo real','bastidores','rascunho')
) as x(kind, title, caption, model, status)
where w.slug = 'em-digital'
and not exists (select 1 from public.ig_posts p where p.workspace_id = w.id);

-- ---- agenda da EM Digital ----
insert into public.agenda_events (workspace_id, title, kind, starts_at)
select id, x.title, x.kind, (current_date + x.d)::timestamptz + x.h
from public.workspaces w,
(values
  ('Onboarding — Pet Shop Amigo Fiel','marco',    1, interval '10 hour'),
  ('Reunião de captação',             'evento',   2, interval '15 hour'),
  ('Fechar proposta Advocacia Menezes','tarefa',  0, interval '9 hour'),
  ('Renovar assinatura Claude',       'vencimento',5, interval '8 hour')
) as x(title, kind, d, h)
where w.slug = 'em-digital'
and not exists (select 1 from public.agenda_events a where a.workspace_id = w.id);
