// Supabase Edge Function: ai
// Edição do design por linguagem natural com o Claude (tool use).
// Recebe { ws, instruction, w, h, elements[], attachments[] } e devolve
// { operations[], reply } que o hub aplica no editor.
//
// Secrets: ANTHROPIC_API_KEY (crie em console.anthropic.com).
// (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já são injetados.)
// Deploy: função "ai" com "Verify JWT" DESLIGADO (auth é feita no código).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") || "";
const BUCKET = "canva-thumbs";

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });

const TOOL = {
  name: "apply_edits",
  description: "Aplica edições no design de rede social. Retorne só as operações necessárias para atender o pedido.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      operations: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            op: { type: "string", enum: ["set_text", "set_color", "set_size", "move", "replace_image", "add_text", "delete"] },
            index: { type: "integer", description: "índice do elemento na lista fornecida" },
            text: { type: "string" },
            color: { type: "string", description: "cor hex, ex #22E07C" },
            size: { type: "number", description: "tamanho da fonte em pt" },
            x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" },
            attachment: { type: "integer", description: "índice do anexo (a partir de 0) a usar como imagem" },
          },
          required: ["op"],
        },
      },
      reply: { type: "string", description: "mensagem curta em português confirmando o que foi feito" },
    },
    required: ["operations", "reply"],
  },
};

async function userFromJwt(jwt: string) {
  const { data } = await admin.auth.getUser(jwt);
  return data.user;
}
async function isMember(ws: string, uid: string) {
  const { data } = await admin.from("memberships").select("id").eq("workspace_id", ws).eq("user_id", uid).limit(1);
  return !!(data && data.length);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" } });
  }
  try {
    const url = new URL(req.url);
    const jwt = url.searchParams.get("jwt") || "";
    const user = jwt ? await userFromJwt(jwt) : null;
    if (!user) return json({ error: "não autenticado" }, 401);
    if (!ANTHROPIC_KEY) return json({ error: "ANTHROPIC_API_KEY não configurada nos secrets" }, 500);

    const body = await req.json();
    const ws = body.ws as string | undefined;
    if (ws && !(await isMember(ws, user.id))) return json({ error: "sem acesso" }, 403);
    const instruction = String(body.instruction || "").trim();
    if (!instruction) return json({ error: "faltou instruction" }, 400);
    const elements = Array.isArray(body.elements) ? body.elements : [];
    const attachments = Array.isArray(body.attachments) ? body.attachments : [];
    const w = body.w || 1080, h = body.h || 1350;

    // sobe os anexos pro Storage (service role) e monta os blocos de imagem pro Claude
    const urls: (string | null)[] = [];
    const imgBlocks: unknown[] = [];
    for (const a of attachments) {
      if (!a || !a.data) { urls.push(null); continue; }
      const mt = a.media_type || "image/png";
      const bytes = Uint8Array.from(atob(a.data), (c) => c.charCodeAt(0));
      const ext = mt.includes("jpeg") || mt.includes("jpg") ? "jpg" : mt.includes("webp") ? "webp" : "png";
      const path = `ai/${ws || "anon"}/${crypto.randomUUID()}.${ext}`;
      await admin.storage.from(BUCKET).upload(path, bytes, { contentType: mt, upsert: true });
      urls.push(admin.storage.from(BUCKET).getPublicUrl(path).data.publicUrl);
      imgBlocks.push({ type: "image", source: { type: "base64", media_type: mt, data: a.data } });
    }

    const prompt = `Você é um editor de design gráfico para posts de redes sociais.
Slide: ${w} x ${h} px (origem no canto superior esquerdo; x cresce para a direita, y para baixo).
Elementos atuais (índice: dados):
${elements.map((e: any) => `${e.i}: ${e.type}${e.text ? ` "${e.text}"` : ""} pos(${e.x},${e.y}) tam(${e.w}x${e.h})${e.color ? ` cor ${e.color}` : ""}${e.size ? ` fonte ${e.size}pt` : ""}`).join("\n")}
${attachments.length ? `O usuário anexou ${attachments.length} imagem(ns) (mostradas acima); use "attachment": índice (a partir de 0) para inseri-las.` : ""}
Pedido do usuário: "${instruction}"
Use a ferramenta apply_edits. Edite só o que o pedido pede. Para trocar uma foto por um anexo, use replace_image no índice do elemento de imagem correspondente com o "attachment" certo. Escreva "reply" curto, em português.`;

    const content = [...imgBlocks, { type: "text", text: prompt }];
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: "claude-haiku-4-5", // barato (~R$0,02/edição); troque por claude-opus-4-8 se quiser mais capacidade
        max_tokens: 4096,
        tools: [TOOL],
        tool_choice: { type: "tool", name: "apply_edits" },
        messages: [{ role: "user", content }],
      }),
    });
    if (!res.ok) return json({ error: "claude " + res.status + " " + (await res.text()).slice(0, 300) }, 500);
    const data = await res.json();
    const tu = (data.content || []).find((b: any) => b.type === "tool_use");
    if (!tu) return json({ error: "sem resposta do modelo" }, 500);
    const out = tu.input || { operations: [], reply: "" };
    for (const o of (out.operations || [])) {
      if (o.op === "replace_image" && typeof o.attachment === "number" && urls[o.attachment]) o.src = urls[o.attachment];
    }
    return json({ operations: out.operations || [], reply: out.reply || "Feito." });
  } catch (e) {
    return json({ error: String((e && (e as Error).message) || e) }, 500);
  }
});
