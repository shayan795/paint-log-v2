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
  const select = "id,title,author_label,methods,cover_url,owner_id,is_public,comments_disabled,grid,profiles:owner_id(display_name,user_id)";
  const url = `${env.SUPABASE_URL}/rest/v1/recipes?id=eq.${encodeURIComponent(id)}&is_public=eq.true&select=${encodeURIComponent(select)}`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
      Accept: "application/json",
    },
    // 認可(is_public)依存の取得はキャッシュしない：公開→非公開/削除を即時反映する(Codexレビュー#3)。
    // ページ応答は元々no-cacheでWorkerは毎回走るため、増えるのはSupabase往復1回のみ。
    cf: { cacheTtl: 0 },
  });
  if (!res.ok) return null;
  try {
    const arr = await res.json();
    return arr && arr[0] ? arr[0] : null;
  } catch (_) {
    return null;
  }
}

// レシピから OGP の説明文を作る
// 既存塗料(c.i) と 自由入力(c.c) の両方をユニークに数える
function buildDescription(rec, authorLabel) {
  const grid = rec && rec.grid || {};
  const rows = Array.isArray(grid.rows) ? grid.rows : [];
  const paintKeys = new Set();
  for (const row of rows) {
    if (row && row.cells) {
      for (const k of Object.keys(row.cells)) {
        const c = row.cells[k];
        if (!c) continue;
        if (typeof c.i === "number") paintKeys.add("i:" + c.i);
        else if (c.c) paintKeys.add("c:" + c.c);
      }
    }
  }
  const groups = rows.filter(r => r && r.part && String(r.part).trim()).length;
  const bits = [];
  if (authorLabel) bits.push(`制作者 ${authorLabel}`);
  if (groups) bits.push(`${groups}色グループ`);
  if (paintKeys.size) bits.push(`使用塗料 ${paintKeys.size}種`);
  if (!bits.length) bits.push("ガンプラ・模型の塗装レシピ");
  return bits.join(" / ") + " — 塗装レシピ録で記録・共有";
}

const CT_BY_EXT = {
  html: "text/html; charset=utf-8", js: "text/javascript; charset=utf-8",
  css: "text/css; charset=utf-8", json: "application/json; charset=utf-8",
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
  webp: "image/webp", svg: "image/svg+xml", ico: "image/x-icon",
  txt: "text/plain; charset=utf-8", woff: "font/woff", woff2: "font/woff2",
  webmanifest: "application/manifest+json; charset=utf-8",
  xml: "application/xml; charset=utf-8",
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
    // 外部メタ(og/twitter/JSON-LD)の「制作者」は検証済みの display_name / @user_id のみ採用する。
    // 自由入力の author_label は身元未検証のため外部メタには出さない（なりすまし・スパム表示の防止）。
    const authorLabel = (prof.display_name && prof.display_name.trim())
      ? prof.display_name.trim()
      : (prof.user_id ? "@" + prof.user_id : "");
    const title = (rec.title && rec.title.trim() ? rec.title.trim() + "｜" : "") + "塗装レシピ録";
    const desc = buildDescription(rec, authorLabel);
    // cover_url は所有者がAPIで任意値に設定可能なため、Supabase Storage か自サイト由来のみ採用。
    // それ以外（外部の悪意画像等）は汎用OGPにフォールバック。
    const fallbackImg = `${env.SITE}/og-image.png`;
    const cover = String(rec.cover_url || "");
    const image = (cover.startsWith(env.SUPABASE_URL) || cover.startsWith(env.SITE)) ? cover : fallbackImg;
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

    // 構造化データ(JSON-LD)。検索エンジンにレシピ情報を機械可読で渡す（リッチ表示・理解の助け）。
    // 万一例外が出てもページを壊さないよう try/catch で握りつぶす（低リスク優先）。本文HTMLには一切触れない。
    let ldBlock = "";
    try {
      const ld = {
        "@context": "https://schema.org",
        "@type": "Article",
        "headline": (rec.title && rec.title.trim()) ? rec.title.trim() : "塗装レシピ",
        "description": desc,
        "url": pageUrl,
        "inLanguage": "ja",
        "isPartOf": { "@type": "WebSite", "name": "塗装レシピ録 / Paint Log", "url": env.SITE },
      };
      if (image) ld.image = [image];
      if (authorLabel) ld.author = { "@type": "Person", "name": authorLabel };
      ldBlock = `<script type="application/ld+json">${JSON.stringify(ld).replace(/<\/script/gi, "<\\/script")}</script>`;
    } catch (_) { ldBlock = ""; }

    html = html.replace(/<!--OG_START-->[\s\S]*?<!--OG_END-->/, `<!--OG_START-->${block}${ldBlock}<!--OG_END-->`);

    // クライアント側の Supabase ラウンドトリップを消すため、レシピ本体を script タグに埋め込む
    // legacy.html の loadById がこれを優先的に使う
    const initialData = JSON.stringify(rec).replace(/<\/script/gi, "<\\/script");
    const inject = `<script id="__initial_recipe">window.__INITIAL_RECIPE__=${initialData};</script>`;
    html = html.replace(/<\/head>/i, inject + "</head>");
  }
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-cache" },
  });
}

// 動的サイトマップ: 固定ページ＋全公開投稿の /r/:id を列挙してGoogleに知らせる
async function serveSitemap(env) {
  const SITE = env.SITE;
  const staticPages = [
    { loc: SITE + "/",            priority: "1.0", changefreq: "daily"   },
    { loc: SITE + "/course.html", priority: "0.6", changefreq: "monthly" },
    { loc: SITE + "/help.html",   priority: "0.4", changefreq: "monthly" },
    { loc: SITE + "/terms.html",  priority: "0.2", changefreq: "yearly"  },
    { loc: SITE + "/privacy.html",priority: "0.2", changefreq: "yearly"  },
  ];

  let recipes = [];
  try {
    const u = `${env.SUPABASE_URL}/rest/v1/recipes?is_public=eq.true&select=id,created_at&order=created_at.desc&limit=5000`;
    const res = await fetch(u, {
      headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`, Accept: "application/json" },
      cf: { cacheTtl: 600 },
    });
    if (res.ok) recipes = await res.json();
  } catch (_) {}

  const urls = [];
  for (const p of staticPages) {
    urls.push(`<url><loc>${p.loc}</loc><changefreq>${p.changefreq}</changefreq><priority>${p.priority}</priority></url>`);
  }
  for (const r of recipes) {
    const lastmod = r.created_at ? `<lastmod>${String(r.created_at).slice(0,10)}</lastmod>` : "";
    urls.push(`<url><loc>${SITE}/r/${r.id}</loc>${lastmod}<changefreq>weekly</changefreq><priority>0.8</priority></url>`);
  }

  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>`;
  return new Response(xml, {
    headers: { "content-type": "application/xml; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // /sitemap.xml — 公開投稿を動的列挙
    if (path === "/sitemap.xml") return serveSitemap(env);

    // /robots.txt — Worker で明示的に返す（GitHub proxy や Cloudflare 既定に依存しない）
    if (path === "/robots.txt") {
      const body = `User-agent: *\nAllow: /\n\nDisallow: /diagnostics.html\nDisallow: /goodbye.html\n\nSitemap: ${env.SITE}/sitemap.xml\n`;
      return new Response(body, { headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "public, max-age=3600" } });
    }

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
