// Supabase Edge Function: canva
// Faz o OAuth (Canva Connect API) e sincroniza a pasta do Canva -> public.templates.
// Rotas (por caminho): /canva/start, /canva/callback, /canva/sync
//
// Secrets necessários (Dashboard -> Edge Functions -> Secrets):
//   CANVA_CLIENT_ID      = OC-AZ9yzRw7u1o7
//   CANVA_CLIENT_SECRET  = (o secret gerado no Canva)
//   CANVA_REDIRECT_URI   = https://<ref>.supabase.co/functions/v1/canva/callback
//   HUB_RETURN_URL       = http://localhost:8000/hub.html   (pra onde volta depois)
// (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já são injetados automaticamente.)
//
// Deploy: criar a função "canva" com "Verify JWT" DESLIGADO (o callback do
// Canva não manda JWT do Supabase).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CLIENT_ID = Deno.env.get("CANVA_CLIENT_ID")!;
const CLIENT_SECRET = Deno.env.get("CANVA_CLIENT_SECRET")!;
const REDIRECT_URI = Deno.env.get("CANVA_REDIRECT_URI")!;
const HUB_RETURN = Deno.env.get("HUB_RETURN_URL") || "http://localhost:8000/hub.html";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SCOPES = "profile:read folder:read design:meta:read design:content:read asset:read";
const AUTH_URL = "https://www.canva.com/api/oauth/authorize";
const TOKEN_URL = "https://api.canva.com/rest/v1/oauth/token";
const API = "https://api.canva.com/rest/v1";
const BUCKET = "canva-thumbs";

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

function b64url(bytes: Uint8Array) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const rand = (n = 48) => b64url(crypto.getRandomValues(new Uint8Array(n)));
async function sha256(v: string) {
  return b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v))));
}
const redirect = (url: string) => new Response(null, { status: 302, headers: { Location: url } });
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });

async function userFromJwt(jwt: string) {
  const { data } = await admin.auth.getUser(jwt);
  return data.user;
}
async function isMember(ws: string, uid: string) {
  const { data } = await admin.from("memberships").select("id").eq("workspace_id", ws).eq("user_id", uid).limit(1);
  return !!(data && data.length);
}

async function tokenRequest(body: Record<string, string>) {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "authorization": "Basic " + btoa(`${CLIENT_ID}:${CLIENT_SECRET}`),
    },
    body: new URLSearchParams(body).toString(),
  });
  if (!res.ok) throw new Error("token " + res.status + " " + (await res.text()));
  return await res.json();
}

async function validToken(ws: string) {
  const { data } = await admin.from("canva_tokens").select("*").eq("workspace_id", ws).limit(1);
  const row = data && data[0];
  if (!row) throw new Error("workspace sem token do Canva");
  if (new Date(row.expires_at).getTime() > Date.now() + 60000) return row.access_token;
  const t = await tokenRequest({ grant_type: "refresh_token", refresh_token: row.refresh_token });
  await admin.from("canva_tokens").update({
    access_token: t.access_token,
    refresh_token: t.refresh_token || row.refresh_token,
    expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("workspace_id", ws);
  return t.access_token;
}

function inferFormat(w: number, h: number, pages: number) {
  const r = w && h ? w / h : 1;
  if (pages && pages > 1) return "carrossel";
  if (r <= 0.62) return "story";
  if (r > 0.72 && r < 0.9) return "carrossel";
  return "post";
}

async function cacheThumb(ws: string, id: string, url: string) {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const ct = res.headers.get("content-type") || "image/png";
    const ext = ct.includes("jpeg") ? "jpg" : ct.includes("webp") ? "webp" : "png";
    const path = `${ws}/${id}.${ext}`;
    const buf = new Uint8Array(await res.arrayBuffer());
    const up = await admin.storage.from(BUCKET).upload(path, buf, { contentType: ct, upsert: true });
    if (up.error) return null;
    const { data } = admin.storage.from(BUCKET).getPublicUrl(path);
    return { url: data.publicUrl, path };
  } catch (_) {
    return null;
  }
}

async function syncFolder(ws: string, folderId: string, token: string) {
  const seen: string[] = [];
  let cont: string | undefined;
  do {
    const u = new URL(`${API}/folders/${folderId}/items`);
    if (cont) u.searchParams.set("continuation", cont);
    const res = await fetch(u.toString(), { headers: { authorization: "Bearer " + token } });
    if (!res.ok) throw new Error("folder " + res.status + " " + (await res.text()));
    const data = await res.json();
    for (const it of (data.items || [])) {
      const d = it.design || (it.type === "design" ? it : null);
      if (!d || !d.id) continue;
      const thumb = d.thumbnail || {};
      const w = thumb.width || 0, h = thumb.height || 0;
      const pages = d.page_count || 1;
      let thumbUrl: string | null = thumb.url || null;
      let thumbPath: string | null = null;
      if (thumbUrl) {
        const c = await cacheThumb(ws, d.id, thumbUrl);
        if (c) { thumbUrl = c.url; thumbPath = c.path; }
      }
      await admin.from("templates").upsert({
        workspace_id: ws,
        source: "canva",
        canva_design_id: d.id,
        title: d.title || "Sem título",
        format: inferFormat(w, h, pages),
        width: w || null,
        height: h || null,
        page_count: pages,
        thumb_url: thumbUrl,
        thumb_path: thumbPath,
        edit_url: d.urls?.edit_url || null,
        view_url: d.urls?.view_url || null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "workspace_id,canva_design_id" });
      seen.push(d.id);
    }
    cont = data.continuation;
  } while (cont);

  // remove do banco os modelos do Canva que saíram da pasta
  if (seen.length) {
    await admin.from("templates").delete().eq("workspace_id", ws).eq("source", "canva")
      .not("canva_design_id", "in", "(" + seen.join(",") + ")");
  } else {
    await admin.from("templates").delete().eq("workspace_id", ws).eq("source", "canva");
  }
  await admin.from("canva_connections").update({ status: "connected", last_sync_at: new Date().toISOString() }).eq("workspace_id", ws);
  return seen.length;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const route = url.pathname.split("/").filter(Boolean).pop(); // start | callback | sync
  const p = url.searchParams;

  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" },
    });
  }

  try {
    if (route === "start") {
      const ws = p.get("ws") || "", folder = p.get("folder") || "", fname = p.get("fname") || "", jwt = p.get("jwt") || "";
      const user = jwt ? await userFromJwt(jwt) : null;
      if (!user) return json({ error: "não autenticado" }, 401);
      if (!ws || !folder) return json({ error: "faltou ws/folder" }, 400);
      if (!(await isMember(ws, user.id))) return json({ error: "sem acesso a este workspace" }, 403);

      const verifier = rand(48);
      const challenge = await sha256(verifier);
      const state = rand(24);
      await admin.from("canva_oauth_states").insert({
        state, workspace_id: ws, user_id: user.id, code_verifier: verifier, folder_id: folder, folder_name: fname,
      });
      const a = new URL(AUTH_URL);
      a.searchParams.set("code_challenge", challenge);
      a.searchParams.set("code_challenge_method", "S256");
      a.searchParams.set("scope", SCOPES);
      a.searchParams.set("response_type", "code");
      a.searchParams.set("client_id", CLIENT_ID);
      a.searchParams.set("state", state);
      a.searchParams.set("redirect_uri", REDIRECT_URI);
      return redirect(a.toString());
    }

    if (route === "callback") {
      if (p.get("error")) return redirect(HUB_RETURN + "?canva=error");
      const code = p.get("code") || "", state = p.get("state") || "";
      const { data: sd } = await admin.from("canva_oauth_states").select("*").eq("state", state).limit(1);
      const st = sd && sd[0];
      if (!st) return redirect(HUB_RETURN + "?canva=error");

      const t = await tokenRequest({
        grant_type: "authorization_code", code, code_verifier: st.code_verifier, redirect_uri: REDIRECT_URI,
      });
      await admin.from("canva_tokens").upsert({
        workspace_id: st.workspace_id,
        access_token: t.access_token,
        refresh_token: t.refresh_token,
        expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
        updated_at: new Date().toISOString(),
      }, { onConflict: "workspace_id" });
      await admin.from("canva_connections").upsert({
        workspace_id: st.workspace_id, folder_id: st.folder_id, folder_name: st.folder_name,
        status: "connected", connected_by: st.user_id, last_sync_at: new Date().toISOString(),
      }, { onConflict: "workspace_id" });
      await admin.from("canva_oauth_states").delete().eq("state", state);

      try { await syncFolder(st.workspace_id, st.folder_id, t.access_token); } catch (_) { /* segue mesmo se a sync falhar */ }
      return redirect(HUB_RETURN + "?canva=connected");
    }

    if (route === "sync") {
      const ws = p.get("ws") || "", jwt = p.get("jwt") || "";
      const user = jwt ? await userFromJwt(jwt) : null;
      if (!user) return json({ error: "não autenticado" }, 401);
      if (!(await isMember(ws, user.id))) return json({ error: "sem acesso" }, 403);
      const { data: cd } = await admin.from("canva_connections").select("folder_id").eq("workspace_id", ws).limit(1);
      const folder = cd && cd[0] && cd[0].folder_id;
      if (!folder) return json({ error: "Canva não conectado" }, 400);
      const token = await validToken(ws);
      const n = await syncFolder(ws, folder, token);
      return json({ synced: n });
    }

    return json({ ok: true, service: "canva" });
  } catch (e) {
    return json({ error: String((e && (e as Error).message) || e) }, 500);
  }
});
