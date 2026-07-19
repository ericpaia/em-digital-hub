// Supabase Edge Function: instagram
// Puxa o feed (posts) de uma conta via Instagram Graph API usando o token
// guardado em public.ig_connections (a tabela nunca e lida pelo navegador).
//
// Rota:
//   GET /instagram/media?ws=<workspace_id>  -> { media:[...], connected, username }
//
// Secrets (Dashboard -> Edge Functions -> Secrets), OPCIONAL:
//   IG_APP_SECRET = a "Chave secreta do app do Instagram" (so pra trocar token
//                   curto por longo, se necessario). Sem ela, usa o token como esta.
// (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY sao injetados automaticamente.)
//
// Deploy: criar a funcao "instagram" com "Verify JWT" DESLIGADO.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APP_SECRET = Deno.env.get("IG_APP_SECRET") || "";
const IG = "https://graph.instagram.com";

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, apikey",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", ...CORS } });

const DAY = 86400 * 1000;

async function saveToken(ws: string, token: string, expiresInSec: number | null) {
  const expires_at = expiresInSec ? new Date(Date.now() + expiresInSec * 1000).toISOString() : null;
  await admin.from("ig_connections").update({ access_token: token, expires_at, updated_at: new Date().toISOString() }).eq("workspace_id", ws);
}

// Mantem o token longo vivo: troca curto->longo na primeira vez, e renova quando perto de expirar.
async function ensureFresh(ws: string, conn: any): Promise<string> {
  let token = conn.access_token as string;
  try {
    if (!conn.expires_at) {
      if (APP_SECRET) {
        const r = await fetch(`${IG}/access_token?grant_type=ig_exchange_token&client_secret=${encodeURIComponent(APP_SECRET)}&access_token=${encodeURIComponent(token)}`);
        const d = await r.json();
        if (d && d.access_token) { token = d.access_token; await saveToken(ws, token, d.expires_in || 60 * 86400); return token; }
      }
      // Sem secret ou ja era token longo: assume ~58 dias e passa a renovar dai pra frente.
      await saveToken(ws, token, 58 * 86400);
    } else {
      const msLeft = new Date(conn.expires_at).getTime() - Date.now();
      const ageMs = Date.now() - new Date(conn.updated_at || 0).getTime();
      if (msLeft < 10 * DAY && ageMs > DAY) {
        const r = await fetch(`${IG}/refresh_access_token?grant_type=ig_refresh_token&access_token=${encodeURIComponent(token)}`);
        const d = await r.json();
        if (d && d.access_token) { token = d.access_token; await saveToken(ws, token, d.expires_in || 60 * 86400); }
      }
    }
  } catch (_) { /* renovacao e best-effort; segue com o token atual */ }
  return token;
}

// Dados do perfil (foto, contadores, bio). Tenta o conjunto completo e,
// se algum campo nao for suportado, cai pro reduzido pra nao quebrar.
async function fetchProfile(token: string) {
  const full = "user_id,username,name,account_type,profile_picture_url,followers_count,follows_count,media_count,biography,website";
  const safe = "user_id,username,name,account_type,profile_picture_url,followers_count,follows_count,media_count";
  for (const f of [full, safe]) {
    try {
      const r = await fetch(`${IG}/me?fields=${f}&access_token=${encodeURIComponent(token)}`);
      const d = await r.json();
      if (d && !d.error) return d;
    } catch (_) { /* tenta o conjunto reduzido */ }
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  const url = new URL(req.url);
  if (!url.pathname.endsWith("/media")) return json({ error: "not found" }, 404);

  const ws = url.searchParams.get("ws");
  if (!ws) return json({ media: [], connected: false, error: "ws ausente" });

  const { data: rows } = await admin.from("ig_connections").select("*").eq("workspace_id", ws).limit(1);
  const conn = rows && rows[0];
  if (!conn || !conn.access_token) return json({ media: [], connected: false });

  const token = await ensureFresh(ws, conn);
  const profile = await fetchProfile(token);
  const fields = "id,caption,media_type,media_url,permalink,thumbnail_url,timestamp";
  try {
    const r = await fetch(`${IG}/me/media?fields=${fields}&limit=12&access_token=${encodeURIComponent(token)}`);
    const d = await r.json();
    if (d && d.error) return json({ media: [], connected: true, username: conn.username, profile, error: d.error.message || "token" });
    const media = (d.data || [])
      .map((m: any) => ({
        id: m.id,
        type: m.media_type,
        url: m.media_type === "VIDEO" ? (m.thumbnail_url || m.media_url) : (m.media_url || m.thumbnail_url),
        permalink: m.permalink,
        caption: m.caption || "",
      }))
      .filter((m: any) => m.url);
    return json({ media, connected: true, username: conn.username, profile });
  } catch (e) {
    return json({ media: [], connected: true, username: conn.username, profile, error: "rede" });
  }
});
