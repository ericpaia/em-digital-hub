-- ============================================================
-- 003_templates.sql — Biblioteca de modelos (Canva + Claude)
-- Cole no SQL Editor do Supabase e clique em "Run". Idempotente.
--
-- Cadeia mestre -> cópia -> projeto:
--   templates   = modelos MESTRES (pasta do Canva, gerados pelo Claude, ou importados)
--   projects    = a CÓPIA editável do usuário (nunca altera o mestre)
--   deployed_templates = "modelos implantados" (só referência, não duplica)
--   template_favorites = favoritos por usuário
--   canva_connections  = a pasta do Canva conectada por workspace (tokens: Fase 2)
-- ============================================================

-- ---------- conexão com a pasta do Canva (por workspace) ----------
create table if not exists public.canva_connections (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces(id) on delete cascade,
  folder_id     text,
  folder_name   text,
  status        text not null default 'disconnected', -- disconnected, connected, error
  connected_by  uuid references auth.users(id),
  last_sync_at  timestamptz,
  created_at    timestamptz not null default now(),
  unique (workspace_id)
);
-- Obs: os tokens de acesso do Canva NÃO ficam aqui. Na Fase 2 eles são
-- guardados/rotacionados só pela Edge Function (service role), nunca expostos
-- ao navegador.

-- ---------- modelos mestres ----------
create table if not exists public.templates (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references public.workspaces(id) on delete cascade,
  source          text not null default 'import' check (source in ('canva','claude','import')),
  canva_design_id text,
  title           text not null,
  format          text not null default 'post' check (format in ('post','carrossel','story')),
  width           int,
  height          int,
  page_count      int not null default 1,
  thumb_url       text,        -- preview (URL do Canva temporária, ou importada)
  thumb_path      text,        -- cache no Storage (Fase 2)
  niche           text,        -- advocacia, estetica... (livre, expansível)
  category        text,
  tags            text[] not null default '{}',
  style           text,
  edit_url        text,        -- deep link do editor do Canva (Fase 2/3)
  view_url        text,
  content         jsonb,       -- modelo editável nativo (Claude/import) — base do editor
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists templates_ws  on public.templates(workspace_id);
create index if not exists templates_fmt on public.templates(workspace_id, format);

-- ---------- favoritos (por usuário, dentro do workspace) ----------
create table if not exists public.template_favorites (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.templates(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  unique (template_id, user_id)
);

-- ---------- modelos implantados (referência, não cópia) ----------
create table if not exists public.deployed_templates (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.templates(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  deployed_by  uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  unique (template_id, workspace_id)
);

-- ---------- projetos: a cópia editável do usuário ----------
create table if not exists public.projects (
  id                 uuid primary key default gen_random_uuid(),
  workspace_id       uuid not null references public.workspaces(id) on delete cascade,
  source_template_id uuid references public.templates(id) on delete set null,
  source             text not null default 'blank' check (source in ('canva-export','claude','import','blank')),
  canva_design_id    text,
  title              text not null,
  format             text not null default 'post' check (format in ('post','carrossel','story')),
  page_count         int not null default 1,
  content            jsonb,      -- slides/elementos editáveis (formato nativo do Hub)
  file_path          text,       -- pptx/png no Storage, quando houver
  status             text not null default 'draft' check (status in ('draft','ready','published')),
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists projects_ws on public.projects(workspace_id);

-- ============================================================
-- RLS: membro do workspace (ou o owner da agência) faz tudo dentro dele
-- ============================================================
alter table public.canva_connections  enable row level security;
alter table public.templates          enable row level security;
alter table public.template_favorites enable row level security;
alter table public.deployed_templates enable row level security;
alter table public.projects           enable row level security;

do $$
declare t text;
begin
  foreach t in array array['canva_connections','templates','template_favorites','deployed_templates','projects'] loop
    execute format('drop policy if exists %I_rw on public.%I;', t, t);
    execute format(
      'create policy %I_rw on public.%I for all using (public.is_member(workspace_id) or public.is_agency()) with check (public.is_member(workspace_id) or public.is_agency());',
      t, t);
  end loop;
end $$;

-- ============================================================
-- SEED — alguns modelos de exemplo da EM Digital (source=import,
-- sem thumbnail: aparecem como tiles da marca). Some assim que a
-- pasta do Canva for sincronizada. Pode apagar à vontade.
-- ============================================================
insert into public.templates (workspace_id, source, title, format, width, height, page_count, niche, category, tags)
select w.id, 'import', x.title, x.format, x.width, x.height, x.pages, x.niche, x.category, x.tags
from public.workspaces w,
(values
  ('Promo do dia',            'post',      1080,1080, 1, 'Restaurante',  'Promoção',   array['promo','comida','oferta']),
  ('Antes e depois',          'post',      1080,1080, 1, 'Estética',     'Resultado',  array['antes-depois','resultado']),
  ('5 dicas rápidas',         'carrossel', 1080,1350, 5, 'Marketing',    'Educativo',  array['dicas','educativo','lista']),
  ('Passo a passo',           'carrossel', 1080,1350, 7, 'Contabilidade','Educativo',  array['tutorial','passo-a-passo']),
  ('Novidade da semana',      'story',     1080,1920, 1, 'Barbearia',    'Institucional', array['novidade','story']),
  ('Agende seu horário',      'story',     1080,1920, 1, 'Odontologia',  'CTA',        array['agendamento','cta']),
  ('Depoimento de cliente',   'post',      1080,1080, 1, 'Advocacia',    'Prova social', array['depoimento','prova-social']),
  ('Lançamento de imóvel',    'carrossel', 1080,1350, 6, 'Imobiliária',  'Vendas',     array['imovel','lancamento','venda'])
) as x(title, format, width, height, pages, niche, category, tags)
where w.slug = 'em-digital'
and not exists (select 1 from public.templates t where t.workspace_id = w.id);
