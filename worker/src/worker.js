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

// 全レスポンスに付ける安全ヘッダ。
// ※script-src等の本格CSPはインラインscript/styleを多用しているため今は入れない（壊れるため）。
//   ここではサイトを壊さずに効く「クリックジャッキング防止・MIME推測防止・リファラ抑制・HTTPS強制」を入れる。
const SECURITY_HEADERS = {
  "x-content-type-options": "nosniff",
  "x-frame-options": "SAMEORIGIN",
  "content-security-policy": "frame-ancestors 'self'",
  "referrer-policy": "strict-origin-when-cross-origin",
  "strict-transport-security": "max-age=15552000",
};

// 配信してはいけない内部ファイル（GitHub Pagesはリポジトリ全体を公開するため、入口のWorkerで遮断する）。
// 未修正の脆弱性台帳(BOMBS.md)やDB定義(schema.sql/migrations)が誰でも読める状態を塞ぐ。
function isBlockedPath(p) {
  // ★URLエンコード（%2E=. %2F=/ など）を先に元へ戻してから判定する。
  //   デコードしないと /%2Egithub/ や /BOMBS%2Emd のような書き方で遮断をすり抜けられる。
  let s = p;
  for (let i = 0; i < 3; i++) {            // 二重・三重エンコードにも対応
    try { const d = decodeURIComponent(s); if (d === s) break; s = d; } catch (_) { break; }
  }
  s = s.toLowerCase().replace(/\\/g, "/").replace(/\/{2,}/g, "/");
  // 許可リスト方式に近い形へ寄せる：配信して良い拡張子だけを通し、それ以外の「素の名前」は落とす
  if (/^\/(supabase|migrations|worker|scripts|tests|docs|backups|\.github|\.git|node_modules)\//.test(s)) return true;
  if (/\.(sql|md|toml|lock|log|mjs|sh|yml|yaml|txt|map|bak|old|orig|swp)$/.test(s)) return true;
  if (/^\/(package(-lock)?\.json|\.gitignore|\.env.*|claude.*|.*引き継ぎ.*|bombs.*|readme.*)$/.test(s)) return true;
  if (/^\/v1-reference\.html$/.test(s)) return true;   // 旧参考ファイル（XSSが残っている）
  if (/\/\.\.?(\/|$)/.test(s)) return true;            // パストラバーサル
  return false;
}

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// og:image に使ってよい画像URLか（Supabase Storage か自サイトの「オリジン完全一致」のみ許可）。
// 前方一致だと supabase.co.evil.com のような外部ドメインを通してしまうため必ずURL解析で判定する。
function isAllowedImageOrigin(u, env) {
  try {
    const o = new URL(String(u || "")).origin;
    return o === new URL(env.SUPABASE_URL).origin || o === new URL(env.SITE).origin;
  } catch (_) { return false; }
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
  // 取得失敗(Supabase障害等)は null ではなく "error" を返す。
  // null(=本当に存在しない/非公開)と区別しないと、一時障害の間だけ正常な公開レシピにも
  // 404 を返してしまい検索インデックスから外れる。
  if (!res.ok) return "error";
  try {
    const arr = await res.json();
    return arr && arr[0] ? arr[0] : null;
  } catch (_) {
    return "error";
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
// レシピIDがUUIDの形をしているか。形が違うものはSupabaseに問い合わせるまでもなく存在しない。
// 検証しないと、任意の文字列で無制限に上流照会を発生させられる（無料枠の消費・障害の誘発）。
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 存在しないレシピURLの応答（検索結果に中身の無いページを残さないため 404 + noindex）
function notFoundRecipe(env) {
  return new Response(
    "<!doctype html><meta charset=utf-8><meta name=\"robots\" content=\"noindex,follow\">"
    + "<title>ページが見つかりません — 塗装レシピ録</title>"
    + "<body style=\"font-family:-apple-system,sans-serif;padding:48px 24px;text-align:center;color:#555\">"
    + "<h1 style=\"font-size:1.2rem;color:#1E2430\">このレシピは見つかりませんでした</h1>"
    + "<p>削除されたか、非公開に変更された可能性があります。</p>"
    + "<p><a href=\"" + esc(env.SITE) + "/\">トップへ戻る</a></p></body>",
    { status: 404, headers: { "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store", ...SECURITY_HEADERS } });
}

async function serveRecipePage(env, id) {
  // 形式が不正なIDは、上流に問い合わせず即座に404にする
  if (!UUID_RE.test(String(id || ""))) return notFoundRecipe(env);
  let rec = await getRecipeFromSupabase(env, id);
  const fetchFailed = (rec === "error");
  if (fetchFailed) rec = null;
  // 配信元(GitHub raw)が落ちた/404を返した場合に、そのエラー本文をレシピページとして
  // 200で返してしまわないようにする（503を返す）。
  let originRes, html;
  try {
    originRes = await fetchOrigin(env, "/legacy.html");
    if (!originRes || !originRes.ok) throw new Error("origin " + (originRes && originRes.status));
    html = await originRes.text();
  } catch (_) {
    return new Response("<!doctype html><meta charset=utf-8><title>一時的にアクセスできません</title><p>ただいま混み合っています。しばらくしてからお試しください。",
      { status: 503, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  }

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
    // ★前方一致(startsWith)だと https://<ref>.supabase.co.evil.com/... が通ってしまうため、
    //   URLとして解析し「オリジン完全一致」で判定する。
    const image = isAllowedImageOrigin(cover, env) ? cover : fallbackImg;
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
        // 発行元とロゴ。Googleが検索結果でサイトのアイコン/ロゴを認識するための正式な手がかり。
        // ロゴ画像はファイル名にバージョンを付けて配信しているため、変更時はここも合わせる。
        "publisher": {
          "@type": "Organization",
          "name": "塗装レシピ録 / Paint Log",
          "url": env.SITE,
          "logo": { "@type": "ImageObject", "url": `${env.SITE}/assets/favicon-512.png?v=2` },
        },
      };
      if (image) ld.image = [image];
      if (authorLabel) ld.author = { "@type": "Person", "name": authorLabel };
      // ★`</script` を潰すだけでは足りない。レシピtitleに `<!--<script>` を入れられると
      //   HTMLパーサがscript内でコメント状態に入り、後続のページ本文を丸ごと飲み込んで
      //   公開レシピページが崩壊する。`<` を全て \u003c にすれば構造上の脱出が不可能になる
      //   （JSONとしての値は同じなので検索エンジンの読み取りには影響しない）。
      ldBlock = `<script type="application/ld+json">${JSON.stringify(ld).replace(/</g, "\\u003c")}</script>`;
    } catch (_) { ldBlock = ""; }

    // ★replace の第2引数は必ず「関数」にすること（文字列だと $' `$&` 等が特殊置換として展開され、
    //   レシピtitle等のユーザー入力から本文が複製され、注入scriptが早期終了して保存型XSSになる）。
    html = html.replace(/<!--OG_START-->[\s\S]*?<!--OG_END-->/, () => `<!--OG_START-->${block}${ldBlock}<!--OG_END-->`);

    // クライアント側の Supabase ラウンドトリップを消すため、レシピ本体を script タグに埋め込む
    // legacy.html の loadById がこれを優先的に使う
    // < を < に落として script の早期終了自体を封じる（</script 対策の上位互換・JSONとしては同値）
    const initialData = JSON.stringify(rec).replace(/</g, "\\u003c");
    const inject = `<script id="__initial_recipe">window.__INITIAL_RECIPE__=${initialData};</script>`;
    html = html.replace(/<\/head>/i, () => inject + "</head>");
    // canonical をこのレシピ自身に向ける。既定のままだとトップページを指し、
    // 全レシピページが「重複」と判定されて検索インデックスから消える。
    html = html.replace(/<!--CANON_START-->[\s\S]*?<!--CANON_END-->/,
      () => `<!--CANON_START--><link rel="canonical" href="${esc(pageUrl)}"><!--CANON_END-->`);
  } else {
    // 非公開化・削除済み・不正IDのレシピURL：ソフト404を避け、404 + noindex を返す
    // （200のままだと検索結果に中身の無いページが残り続ける）
    // ただし取得失敗(Supabase障害)のときは 404 にしない。正常な公開レシピを一時障害で
    // インデックスから落とさないため、200のまま返してクライアント側の再取得に委ねる。
    // ★取得失敗(Supabase障害)は「存在しない」ではなく「今は応えられない」なので 503 を返す。
    //   200 + noindex にすると、一時障害の間に来た検索エンジンが正常なレシピを
    //   「インデックス不可」と受け取ってしまう。503 なら後で再訪してくれる。
    if (fetchFailed) {
      return new Response(
        "<!doctype html><meta charset=utf-8><title>一時的に表示できません</title>"
        + "<p>ただいま混み合っています。少し時間をおいて再読み込みしてください。",
        { status: 503, headers: { "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store", "retry-after": "60", ...SECURITY_HEADERS } });
    }
    html = html.replace(/<!--CANON_START-->[\s\S]*?<!--CANON_END-->/,
      () => `<!--CANON_START--><meta name="robots" content="noindex,follow"><!--CANON_END-->`);
    return new Response(html, {
      status: 404,
      headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", ...SECURITY_HEADERS },
    });
  }
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-cache", ...SECURITY_HEADERS },
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

    // www は apex(plamo-paint.com) に寄せる。
    // 両方で同じアプリを配信していたが、Supabaseのリダイレクト許可リストに www が
    // 入っていないため、www 側から入った人はログイン後の戻り先が拒否されて認証が失敗する。
    // ホストを1つに統一すれば、その経路自体が無くなる（SEOの重複対策にもなる）。
    if (url.hostname === "www.plamo-paint.com") {
      url.hostname = "plamo-paint.com";
      return Response.redirect(url.toString(), 301);
    }

    // /healthz — 外部の死活監視用。★配信元とデータベースの両方を実際に確認する。
    // トップページは静的なので「表示できる＝正常」とは限らず、DBが死んでいても200が返ってしまう。
    // ここは本当に壊れたときだけ503を返すので、UptimeRobot等でここを監視すれば故障を検知できる。
    // 副次効果: 定期的にSupabaseへ問い合わせるため、無料プランの「7日間アクセスが無いと
    //          自動停止」も防げる（停止するとサイトが全断するため実質必須）。
    if (path === "/healthz") {
      const out = { ok: true, checks: {} };
      try {
        const r = await fetch(`${env.SUPABASE_URL}/rest/v1/paints?select=id&limit=1`, {
          headers: { apikey: env.SUPABASE_ANON_KEY, authorization: `Bearer ${env.SUPABASE_ANON_KEY}` },
          cf: { cacheTtl: 0 },
        });
        out.checks.database = r.ok ? "ok" : `ng(${r.status})`;
        if (!r.ok) out.ok = false;
      } catch (e) { out.checks.database = "ng(unreachable)"; out.ok = false; }
      try {
        const r = await fetch(`${env.ORIGIN}/index.html`, { cf: { cacheTtl: 0 } });
        out.checks.origin = r.ok ? "ok" : `ng(${r.status})`;
        if (!r.ok) out.ok = false;
      } catch (e) { out.checks.origin = "ng(unreachable)"; out.ok = false; }
      return new Response(JSON.stringify(out), {
        status: out.ok ? 200 : 503,
        headers: { ...SECURITY_HEADERS, "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
      });
    }

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

    // 内部ファイル（DB定義・migration・脆弱性台帳・設定ファイル等）は配信しない
    if (isBlockedPath(path)) return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });

    // それ以外は GitHub Pages の中身を配信（raw は text/plain で返るので拡張子から content-type を再設定）
    const reqPath = path === "/" ? "/index.html" : path;
    let originRes;
    try {
      originRes = await fetchOrigin(env, reqPath, url.search);
    } catch (_) {
      return new Response("Service Unavailable", { status: 503, headers: { ...SECURITY_HEADERS, "cache-control": "no-store" } });
    }
    if (originRes.status === 404) return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });
    // 404以外のエラー(403/429/5xx等)は本文を素通ししない。
    // 配信元は raw.githubusercontent.com で、アクセス集中時に 403/429 を返すことがある。
    // これをそのまま max-age=300 で返すと「バズった瞬間にGitHubのエラー文が5分間貼り付く」ため、
    // 必ず 503 + no-store にしてリロードで復帰できるようにする。
    if (originRes.status >= 400) {
      return new Response("<!doctype html><meta charset=utf-8><title>一時的にアクセスできません</title><p>ただいま混み合っています。少し時間をおいて再読み込みしてください。",
        { status: 503, headers: { ...SECURITY_HEADERS, "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
    }
    const h = new Headers(SECURITY_HEADERS);
    h.set("content-type", ctForPath(reqPath));
    // 画像・フォント等の不変アセットは長め、HTML/JS等は短めにして更新の伝播を早くする
    const immutable = /\.(png|jpe?g|gif|webp|svg|ico|woff2?)$/i.test(reqPath);
    h.set("cache-control", immutable ? "public, max-age=86400" : "public, max-age=300");
    return new Response(originRes.body, { status: originRes.status, headers: h });
  },
};
