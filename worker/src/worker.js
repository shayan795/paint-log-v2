// 塗装レシピ録 V2 — Cloudflare Worker
// 役割:
//  - 短縮URL /r/:id を受けて、Supabaseからレシピを取得 → 動的OGPを注入した HTML を返す
//  - legacy.html?id=xxx も同様に動的OGP化（バックワード互換）
//  - 上記以外は GitHub Pages の paint-log-v2 リポジトリへプロキシ
//
// 必要な環境変数（wrangler secret put / vars）:
//   SUPABASE_URL      …  https://xxxx.supabase.co
//   SUPABASE_ANON_KEY …  anon public key（RLS で保護されるため Worker に置いてもOK）
//   ORIGIN            …  https://raw.githubusercontent.com/<user>/<repo>/<branch>
//   SITE              …  https://plamo-paint.com

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// Supabase REST API から1件レシピを取得
async function getRecipeFromSupabase(env, id) {
  // 公開投稿のみ取得（is_public=true）
  const select = "id,title,author_label,methods,cover_url,owner_id,is_public,grid,profiles:owner_id(display_name,user_id)";
  const url = `${env.SUPABASE_URL}/rest/v1/recipes?id=eq.${encodeURIComponent(id)}&is_public=eq.true&select=${encodeURIComponent(select)}`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
      Accept: "application/json",
    },
    cf: { cacheTtl: 60 },
  });
  if (!res.ok) return null;
  try {
    const arr = await res.json();
    return arr && arr[0] ? arr[0] : null;
  } catch (_) {
    return null;
  }
}

// レシピから OGP の説明文を作る（V1と同じ式）
function buildDescription(rec, authorLabel) {
  const grid = rec && rec.grid || {};
  const rows = Array.isArray(grid.rows) ? grid.rows : [];
  const paintNames = new Set();
  for (const row of rows) {
    if (row && row.cells) {
      for (const k of Object.keys(row.cells)) {
        const c = row.cells[k];
        if (c && c.c) paintNames.add(c.c);
      }
    }
  }
  const groups = rows.filter(r => r && r.part && String(r.part).trim()).length;
  const bits = [];
  if (authorLabel) bits.push(`制作者 ${authorLabel}`);
  if (groups) bits.push(`${groups}色グループ`);
  if (paintNames.size) bits.push(`使用塗料 ${paintNames.size}種`);
  if (!bits.length) bits.push("ガンプラ・模型の塗装レシピ");
  return bits.join(" / ") + " — 塗装レシピ録で記録・共有";
}

const CT_BY_EXT = {
  html: "text/html; charset=utf-8", js: "text/javascript; charset=utf-8",
  css: "text/css; charset=utf-8", json: "application/json; charset=utf-8",
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
  webp: "image/webp", svg: "image/svg+xml", ico: "image/x-icon",
  txt: "text/plain; charset=utf-8", woff: "font/woff", woff2: "font/woff2",
};
function ctForPath(p) {
  const m = p.match(/\.([a-z0-9]+)$/i);
  return (m && CT_BY_EXT[m[1].toLowerCase()]) || "text/html; charset=utf-8";
}

// GitHub raw から原本を取得
async function fetchOrigin(env, pathname, search = "") {
  const url = env.ORIGIN + pathname + (search || "");
  return fetch(url, { cf: { cacheTtl: 300 } });
}

// /r/:id または ?id=xxx を含むレシピ閲覧ページ：OGタグを差し込んだ legacy.html を返す
async function serveRecipePage(env, id) {
  const rec = await getRecipeFromSupabase(env, id);
  const originRes = await fetchOrigin(env, "/legacy.html");
  let html = await originRes.text();

  if (rec) {
    const prof = rec.profiles || {};
    const authorLabel = (prof.display_name && prof.display_name.trim())
      ? prof.display_name.trim()
      : (prof.user_id ? "@" + prof.user_id : (rec.author_label || "").trim());
    const title = (rec.title && rec.title.trim() ? rec.title.trim() + "｜" : "") + "塗装レシピ録";
    const desc = buildDescription(rec, authorLabel);
    const image = rec.cover_url || `${env.SITE}/og-image.png`;
    const pageUrl = `${env.SITE}/r/${rec.id}`;

    const block =
      `<meta property="og:type" content="article">` +
      `<meta property="og:site_name" content="塗装レシピ録 / Paint Log">` +
      `<meta property="og:title" content="${esc(title)}">` +
      `<meta property="og:description" content="${esc(desc)}">` +
      `<meta property="og:url" content="${esc(pageUrl)}">` +
      `<meta property="og:image" content="${esc(image)}">` +
      `<meta property="og:image:width" content="1080">` +
      `<meta property="og:image:height" content="1080">` +
      `<meta property="og:locale" content="ja_JP">` +
      `<meta name="twitter:card" content="summary_large_image">` +
      `<meta name="twitter:title" content="${esc(title)}">` +
      `<meta name="twitter:description" content="${esc(desc)}">` +
      `<meta name="twitter:image" content="${esc(image)}">`;

    html = html.replace(/<!--OG_START-->[\s\S]*?<!--OG_END-->/, `<!--OG_START-->${block}<!--OG_END-->`);
  }
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-cache" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // /r/:id — 短縮URL
    if (path.startsWith("/r/")) {
      const id = path.slice(3).split("/")[0];
      if (id) return serveRecipePage(env, id);
    }

    // /legacy.html?id=xxx — 後方互換（直リンクや既存共有URL）
    if ((path === "/legacy.html" || path === "/legacy") && url.searchParams.get("id")) {
      const id = url.searchParams.get("id");
      return serveRecipePage(env, id);
    }

    // それ以外は GitHub Pages の中身を配信（raw は text/plain で返るので拡張子から content-type を再設定）
    const reqPath = path === "/" ? "/index.html" : path;
    const originRes = await fetchOrigin(env, reqPath, url.search);
    if (originRes.status === 404) return new Response("Not found", { status: 404 });
    const h = new Headers();
    h.set("content-type", ctForPath(reqPath));
    h.set("cache-control", "public, max-age=300");
    return new Response(originRes.body, { status: originRes.status, headers: h });
  },
};
