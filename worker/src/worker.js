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
    // ここの catch は意図的に無言。壊れた%エンコードは攻撃・タイプミスで日常的に飛んでくるため、
    // ログに出すと本当の障害が埋もれる（デコードを諦めた時点の文字列で判定を続ければ安全側）。
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
  } catch (_) {
    // 意図的に無言。cover_url が空・相対URL・不正値なのは「よくある通常ケース」で、
    // ここでログを出すと正常運用のノイズになる（不許可=false に倒すだけで安全）。
    return false;
  }
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
  if (!res.ok) {
    // 何番のレシピで、Supabaseが何のステータスを返したのかを残す（後から原因を特定するため）
    console.error("getRecipeFromSupabase: 応答が異常", res.status, id);
    return "error";
  }
  try {
    const arr = await res.json();
    return arr && arr[0] ? arr[0] : null;
  } catch (e) {
    console.error("getRecipeFromSupabase: JSON解析に失敗", id, e);
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

// ============================================================================
// SSR（サーバー側でレシピ本文をHTMLにして返す）
//
// なぜ必要か:
//   /r/:id は今まで legacy.html に OGP と JSON-LD を差し込むだけで、レシピ本文
//   （部位・工程・塗料名）は全部ブラウザのJavaScriptが描いていた。つまり生のHTMLには
//   文字が1つも無く、検索エンジンから見ると「中身の無いページ」に近かった。
//   集客の核なので、ここでサーバー側でも本文を組み立てて生HTMLに入れる。
//
// 壊さないための約束:
//   ・失敗したら本文を入れずに今までどおり返す（SSRの失敗でページが白くならないこと最優先）
//   ・出力は必ず esc() を通す。replace の第2引数には絶対に文字列を渡さない（$& 等が展開されるため）
//   ・legacy.html のJSが描く #viewMode / #viewTable には一切触らない。独立した
//     #__ssr_recipe というdivに入れ、JSが閲覧画面を出した瞬間に自分で消える。
// ============================================================================

// 本文HTMLの上限（文字数）。長大なレシピでレスポンスが膨らむのを防ぐ。
// 20000文字＝日本語でも十分な分量で、これを超える分は打ち切って「続きはページ内で」に任せる。
const SSR_MAX_CHARS = 20000;

// grid の各マスから「マスタ塗料への参照」を集める。
//   c.id … 安定ID(pt_xxxx)。2026-07以降の正しい指し方
//   c.i  … 塗料リストの並び順(paints.sort_order と同じ)。旧データ互換
// 形の違う値は無視する（直APIで任意のJSONを保存できるため、信用せず門番を置く）。
function collectPaintRefs(grid) {
  const out = { ids: [], idxs: [] };
  try {
    const g = (grid && typeof grid === "object" && !Array.isArray(grid)) ? grid : {};
    const rows = Array.isArray(g.rows) ? g.rows : [];
    const seenId = Object.create(null), seenIdx = Object.create(null);
    for (const row of rows) {
      if (!row || typeof row !== "object" || Array.isArray(row)) continue;
      const cells = (row.cells && typeof row.cells === "object" && !Array.isArray(row.cells)) ? row.cells : {};
      for (const k of Object.keys(cells)) {
        const c = cells[k];
        if (!c || typeof c !== "object" || Array.isArray(c)) continue;
        // 安定IDは pt_ + 16進。この形だけを通すので、URLに混ぜても細工にならない
        if (typeof c.id === "string" && /^pt_[0-9a-f]{6,32}$/.test(c.id) && !seenId[c.id]) {
          seenId[c.id] = 1; out.ids.push(c.id);
        }
        // 並び順は 0以上の整数のみ。小数・負数・NaN・文字列は捨てる
        if (typeof c.i === "number" && isFinite(c.i) && c.i >= 0 && c.i === Math.floor(c.i) && !seenIdx[c.i]) {
          seenIdx[c.i] = 1; out.idxs.push(c.i);
        }
      }
    }
  } catch (_) {
    // 意図的に無言。gridは利用者が直APIで任意の形に保存できるため、想定外の形は「よくあること」。
    // ここで例外を上げるとページ全体が出せなくなるので、集められた分だけで先へ進む。
  }
  return out;
}

// Supabase の paints 応答（配列）を、引きやすい2つの辞書に変換する
function buildPaintMaps(rows) {
  const maps = { byId: Object.create(null), byIdx: Object.create(null) };
  const list = Array.isArray(rows) ? rows : [];
  for (const p of list) {
    if (!p || typeof p !== "object" || Array.isArray(p)) continue;
    const item = {
      brand: p.brand == null ? "" : String(p.brand),
      code: p.code == null ? "" : String(p.code),
      name: p.name == null ? "" : String(p.name),
    };
    if (p.id != null) maps.byId[String(p.id)] = item;
    if (typeof p.sort_order === "number") maps.byIdx[String(p.sort_order)] = item;
  }
  return maps;
}

// 1マス → 画面に出す塗料名。マスタに無ければ手入力(c.c)を使う。どちらも無ければ空文字。
function paintLabel(cell, maps) {
  if (!cell || typeof cell !== "object" || Array.isArray(cell)) return "";
  const m = maps || {};
  const byId = m.byId || {};
  const byIdx = m.byIdx || {};
  let hit = null;
  if (typeof cell.id === "string") hit = byId[cell.id] || null;
  if (!hit && typeof cell.i === "number") hit = byIdx[String(cell.i)] || null;
  if (hit) {
    // 「ブランド 型番 名称」を1つの文字列に。空欄があっても二重スペースにならないよう畳む。
    // ★replaceの第2引数は関数にする（文字列だと $& 等が特殊置換として解釈される決まりにそろえる）
    const s = (hit.brand + " " + hit.code + " " + hit.name).replace(/\s+/g, () => " ");
    if (s.trim()) return s.trim();
  }
  return typeof cell.c === "string" ? cell.c.trim() : "";
}

// レシピ1件 → 生HTMLに入れる本文ブロック。中身が何も無ければ空文字を返す（＝注入しない）。
// maps は fetchPaintMaps() の戻り値。maxChars は本文の文字数上限。
function buildRecipeBodyHtml(rec, maps, maxChars) {
  const LIMIT = (typeof maxChars === "number" && maxChars > 0) ? maxChars : 20000;
  const r = (rec && typeof rec === "object" && !Array.isArray(rec)) ? rec : {};
  const g = (r.grid && typeof r.grid === "object" && !Array.isArray(r.grid)) ? r.grid : {};
  const asStr = v => (v == null ? "" : String(v));
  // 1つの項目だけで応答が肥大化しないよう、項目ごとにも長さの上限を置く。
  // （grid は利用者が直APIで保存できるため、コメント1つに何MBも入れることが理論上できる。
  //   行数の上限だけでは1行で超過してしまうので、ここで先に刈り取る）
  const clip = (s, n) => (s.length > n ? s.slice(0, n) + "…" : s);
  // 表示名は「gridの値」を優先する。閲覧画面(renderViewMode)が state=grid を見て描くので、
  // ここを合わせないとサーバーが出した文とJSが出す文が食い違う。
  const kit = clip(asStr(g.kit).trim() || asStr(r.title).trim(), 200);
  const author = clip(asStr(g.author).trim() || asStr(r.author_label).trim(), 100);
  const memo = clip(asStr(g.memo).trim() || asStr(r.memo).trim(), 2000);

  const procs = (Array.isArray(g.procs) ? g.procs : [])
    .filter(p => p && typeof p === "object" && !Array.isArray(p))
    .map(p => ({ id: asStr(p.id), name: clip(asStr(p.name).trim(), 60) }));
  const rows = (Array.isArray(g.rows) ? g.rows : [])
    .filter(x => x && typeof x === "object" && !Array.isArray(x));

  const cellOf = (row, pid) => {
    const cells = (row.cells && typeof row.cells === "object" && !Array.isArray(row.cells)) ? row.cells : {};
    const c = cells[pid];
    return (c && typeof c === "object" && !Array.isArray(c)) ? c : null;
  };
  // 空の工程列（どの部位にも塗料が入っていない工程）は出さない。閲覧画面と同じ考え方。
  const usedProcs = procs.filter(p => rows.some(row => !!paintLabel(cellOf(row, p.id), maps)));

  // 本文を組み立てる。長さを数えながら足していき、上限に達したら行を打ち切る。
  const seg = [];
  let used = 0;
  const push = s => { seg.push(s); used += s.length; };

  const usedPaints = [];
  const seenPaint = Object.create(null);
  let bodyRows = 0;
  let truncated = false;

  for (const row of rows) {
    const part = clip(asStr(row.part).trim(), 200);
    const comment = clip(asStr(row.comment).trim(), 2000);
    const cellHtml = [];
    let rowHasPaint = false;
    for (const p of usedProcs) {
      const label = clip(paintLabel(cellOf(row, p.id), maps), 200);
      if (label) {
        rowHasPaint = true;
        if (!seenPaint[label]) { seenPaint[label] = 1; usedPaints.push(label); }
      }
      cellHtml.push(`<td>${label ? esc(label) : "—"}</td>`);
    }
    if (!part && !comment && !rowHasPaint) continue;   // 完全に空の行は出さない
    if (used > LIMIT) { truncated = true; break; }
    let tr = `<tr><th scope="row">${esc(part || "—")}</th>${cellHtml.join("")}</tr>`;
    if (comment) {
      tr += `<tr><td colspan="${usedProcs.length + 1}">${esc(comment)}</td></tr>`;
    }
    push(tr);
    bodyRows++;
  }

  // 見出しも本文も無い＝出すものが無い。無理に空の枠だけ出すと逆に品質の低いページになる。
  if (!bodyRows && !kit && !memo) return "";

  const head = usedProcs.map(p => `<th scope="col">${esc(p.name || "工程")}</th>`).join("");
  const tableHtml = bodyRows
    ? `<div class="ssr-scroll"><table><caption class="ssr-cap">部位ごとの塗装手順と使用塗料</caption>`
      + `<thead><tr><th scope="col">部位 / グループ</th>${head}</tr></thead>`
      + `<tbody>${seg.join("")}</tbody></table></div>`
      + (truncated ? `<p class="ssr-more">※ 表示しきれない行があります。ページ内で全体をご覧いただけます。</p>` : "")
    : "";

  // 使用塗料の一覧。塗料名で検索して来た人に当たるよう、表とは別にテキストでも並べる。
  let paintListHtml = "";
  if (usedPaints.length) {
    const items = [];
    let n = 0;
    for (const nm of usedPaints) {
      if (n > 300) break;                       // 常識的な上限（極端なデータでの肥大化防止）
      items.push(`<li>${esc(nm)}</li>`);
      n++;
    }
    paintListHtml = `<h2>使用塗料</h2><ul class="ssr-paints">${items.join("")}</ul>`;
  }

  const titleText = kit ? kit + "｜塗装レシピ" : "塗装レシピ";
  const metaHtml =
    (author ? `<p class="ssr-author">制作者: ${esc(author)}</p>` : "")
    + (memo ? `<p class="ssr-memo">${esc(memo)}</p>` : "");

  // 見た目は最小限。万一このブロックが消えずに残っても崩れて見えないようにする。
  // ★CSSは1行で書くこと（行頭に } を置くと tests/run_worker_tests.mjs の関数抽出が途中で切れる）
  const css = "#__ssr_recipe{max-width:960px;margin:0 auto;padding:16px 14px;"
    + "font-family:-apple-system,BlinkMacSystemFont,'Hiragino Sans',sans-serif;color:#1E2430;line-height:1.7}"
    + "#__ssr_recipe h1{font-size:1.25rem;margin:0 0 10px}"
    + "#__ssr_recipe h2{font-size:1.05rem;margin:22px 0 8px}"
    + "#__ssr_recipe .ssr-author,#__ssr_recipe .ssr-memo{margin:0 0 8px;color:#555}"
    + "#__ssr_recipe .ssr-scroll{overflow-x:auto}"
    + "#__ssr_recipe table{border-collapse:collapse;width:100%;font-size:.92rem}"
    + "#__ssr_recipe th,#__ssr_recipe td{border:1px solid #DDE1E6;padding:6px 8px;text-align:left;vertical-align:top}"
    + "#__ssr_recipe .ssr-cap{text-align:left;font-size:.8rem;color:#777;padding-bottom:6px}"
    + "#__ssr_recipe .ssr-paints{margin:0;padding-left:1.2em}"
    // JSが動く環境では下の編集画面が一瞬見えるのを防ぐ（JSが閲覧画面を出したらこのブロックごと消える）。
    // 通常のCSS規則なので、JS側が要素に直接 style を書けばそちらが勝つ＝編集操作は今までどおり動く。
    + "#editMode{display:none}";

  // JSが閲覧画面(#viewMode)を表示した瞬間に、このブロックを自分で取り除く仕掛け。
  // 検索エンジンはJSを待たずに生HTMLを読むので、消える前の中身が index される。
  // 逆にJSが失敗した場合はこのブロックが残るため、人にも中身が見える（今までは空の編集画面だった）。
  const takeover = "<script>(function(){"
    + "var b=document.getElementById('__ssr_recipe');if(!b)return;var mo=null;"
    + "var done=function(){if(b&&b.parentNode)b.parentNode.removeChild(b);b=null;if(mo){try{mo.disconnect()}catch(e){}mo=null}};"
    + "var shown=function(){var v=document.getElementById('viewMode');"
    + "return !!(v&&v.style&&v.style.display&&v.style.display!=='none')};"
    + "try{mo=new MutationObserver(function(){if(shown())done()});"
    + "mo.observe(document.documentElement,{subtree:true,attributes:true,attributeFilter:['style']})}catch(e){}"
    + "document.addEventListener('DOMContentLoaded',function(){if(shown())done()});"
    + "window.addEventListener('load',function(){if(shown())done()});"
    + "})();<\/script>";

  return `<div id="__ssr_recipe"><style>${css}</style>`
    + `<article><h1>${esc(titleText)}</h1>${metaHtml}`
    + (tableHtml ? `<h2>塗装レシピ</h2>${tableHtml}` : "")
    + `${paintListHtml}</article></div>${takeover}`;
}

// レシピで使われている塗料をまとめて1回で引く。
// 安定ID(id)と旧方式の並び順(sort_order)の両方を or= でまとめ、往復を1回に抑える。
// 取得に失敗したら null を返す（呼び出し側はSSRを諦め、今までどおりのページを返す）。
async function fetchPaintMaps(env, refs) {
  const ids = (refs && Array.isArray(refs.ids) ? refs.ids : []).slice(0, 500);
  const idxs = (refs && Array.isArray(refs.idxs) ? refs.idxs : []).slice(0, 500);
  if (!ids.length && !idxs.length) return { byId: Object.create(null), byIdx: Object.create(null) };
  // ids は pt_[0-9a-f]{6,32}、idxs は0以上の整数だけを collectPaintRefs が通しているので、
  // ここでURLに埋めても細工（クエリの追加・条件の書き換え）は成立しない。
  const conds = [];
  if (ids.length) conds.push(`id.in.(${ids.join(",")})`);
  if (idxs.length) conds.push(`sort_order.in.(${idxs.join(",")})`);
  const u = `${env.SUPABASE_URL}/rest/v1/paints`
    + `?select=id,brand,code,name,sort_order&or=(${conds.join(",")})&limit=2000`;
  try {
    const res = await fetch(u, {
      headers: {
        apikey: env.SUPABASE_ANON_KEY,
        Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
        Accept: "application/json",
      },
      // 塗料マスタは滅多に変わらない読み取り専用データなので、1時間キャッシュして往復を減らす
      cf: { cacheTtl: 3600 },
    });
    if (!res.ok) {
      console.error("fetchPaintMaps: 塗料マスタの応答が異常", res.status);
      return null;
    }
    return buildPaintMaps(await res.json());
  } catch (e) {
    console.error("fetchPaintMaps: 塗料マスタの取得に失敗", e);
    return null;
  }
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
// 静的ファイルの取得。
// ★2026-07-28に「外部の配信元(GitHub Pages)へ取りに行く」から
//   「Cloudflare自身が持っているものを返す」に変更した。
//   理由: 配信元を別ドメインに置くと、そのドメインを直接叩けばこのWorkerを通らないため、
//   内部ファイルの遮断もセキュリティヘッダも一切効かなかった（実際にBOMBS.mdやschema.sqlが
//   誰でも読める状態だった）。同梱すれば入口がこのWorkerだけになり、その抜け道が消える。
//   副次効果: 外部への往復が無くなるので速くなり、配信元の障害でサイトが落ちることも無くなる。
//            さらにコードと静的ファイルが同時に反映されるため、
//            「新しいHTMLと古いJSが混ざる」時間帯（BOMBS B-003）も原理的に生じない。
async function fetchOrigin(env, pathname, search = "") {
  // ASSETS はパスだけを見る。ホスト名は何でもよいが、URLとして成立させる必要がある
  const u = "https://assets.invalid" + pathname + (search || "");
  return env.ASSETS.fetch(new Request(u));
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
  } catch (e) {
    console.error("serveRecipePage: 配信元(legacy.html)の取得に失敗", id, e);
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
    } catch (e) {
      // JSON-LDは「あれば嬉しい」もの。失敗してもページは出すが、原因は残す
      console.error("serveRecipePage: JSON-LDの生成に失敗", id, e);
      ldBlock = "";
    }

    // ★replace の第2引数は必ず「関数」にすること（文字列だと $' `$&` 等が特殊置換として展開され、
    //   レシピtitle等のユーザー入力から本文が複製され、注入scriptが早期終了して保存型XSSになる）。
    html = html.replace(/<!--OG_START-->[\s\S]*?<!--OG_END-->/, () => `<!--OG_START-->${block}${ldBlock}<!--OG_END-->`);

    // <title> をこのレシピ専用にする。
    // ★ここを直さないとSEOの効果が大きく削がれる。検索結果に出る青い見出しは <title> であり、
    //   全レシピが「塗装レシピ録 — プラモデル・模型の塗装レシピ記録ツール」という同じ文字列だと、
    //   利用者から見て中身が区別できず、検索エンジンからも重複扱いされやすい。
    //   （JSが後から書き換えてはいるが、検索エンジンはJSを待たずに読むことがあるため手遅れになる）
    // ★replaceの第2引数は必ず関数（文字列だとレシピ名の $& 等が特殊置換として展開される）。
    if (rec.title && rec.title.trim()) {
      html = html.replace(/<title>[\s\S]*?<\/title>/i, () => `<title>${esc(title)}</title>`);
    }

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

    // --- 本文のSSR（検索エンジンに中身を届けるための要）---
    // ここで失敗しても「本文なしの今までどおりのページ」を返す。SSRのために
    // レシピが表示できなくなるのは本末転倒なので、全体を try で包む。
    try {
      const refs = collectPaintRefs(rec.grid);
      const maps = await fetchPaintMaps(env, refs);
      // maps が null＝塗料マスタを引けなかった。塗料名が全部空の表を出すくらいなら
      // 本文を入れずに返す（中身の薄いページを検索エンジンに見せない）。
      if (maps) {
        const bodyHtml = buildRecipeBodyHtml(rec, maps, SSR_MAX_CHARS);
        // ★replaceの第2引数は必ず関数。文字列にすると本文中の $& 等が特殊置換として
        //   展開され、利用者の入力から本文が複製される（過去のXSS事故と同じ経路）。
        if (bodyHtml) html = html.replace(/<body[^>]*>/i, m => m + bodyHtml);
      }
    } catch (e) {
      console.error("serveRecipePage: 本文のSSRに失敗（本文なしで続行）", id, e);
    }
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

  // ★取得に失敗したときは「レシピ0件のsitemap」を返してはいけない。
  //   Googleはsitemapを"サイトの全体像"として読むため、一時障害の間に空同然のものを渡すと
  //   既に登録済みの全レシピを「もう存在しないページ」と誤解しかねない。
  //   失敗時は503（＝今は答えられない、後で来て）にして、後日クロールし直してもらう。
  let recipes = null;
  try {
    const u = `${env.SUPABASE_URL}/rest/v1/recipes?is_public=eq.true&select=id,created_at&order=created_at.desc&limit=5000`;
    const res = await fetch(u, {
      headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`, Accept: "application/json" },
      cf: { cacheTtl: 600 },
    });
    if (!res.ok) console.error("serveSitemap: Supabaseの応答が異常", res.status);
    else recipes = await res.json();
  } catch (e) {
    console.error("serveSitemap: レシピ一覧の取得に失敗", e);
  }
  // 配列でない（＝取得失敗・想定外の形）ときだけ503。0件の配列は「まだ公開投稿が無い」という
  // 正常な状態なので、固定ページだけのsitemapを普通に返す。
  if (!Array.isArray(recipes)) {
    return new Response("sitemap temporarily unavailable", {
      status: 503,
      headers: { ...SECURITY_HEADERS, "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-store", "retry-after": "600" },
    });
  }

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
    headers: { ...SECURITY_HEADERS, "content-type": "application/xml; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}

// /healthz の直近の結果を60秒だけ覚えておく入れ物。
// 理由: /healthz は認証なしで誰でも叩けるうえ、1回ごとに Supabase と配信元へ実際に問い合わせる。
//       連打されるとその回数だけ上流を叩くことになり、無料枠を他人に消費させられてしまう。
//       監視サービスの間隔は通常1分以上なので、60秒使い回しても故障検知は遅れない。
// 注意: Cloudflare Workerは実行環境（isolate）が複数あり、この変数はその1つの中だけで共有される。
//       完全な抑制ではないが「1つの環境で秒間何十回」という一番効く形の連打は確実に抑えられる。
const HEALTH_CACHE_MS = 60000;
let healthCache = null;   // { at: 時刻(ms), body: 文字列, status: 数値 }

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
      const now = Date.now();
      // 60秒以内に調べた結果があれば、上流を叩かずそれをそのまま返す（連打対策）
      if (healthCache && (now - healthCache.at) < HEALTH_CACHE_MS) {
        return new Response(healthCache.body, {
          status: healthCache.status,
          headers: { ...SECURITY_HEADERS, "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store", "x-health-cache": "hit" },
        });
      }
      const out = { ok: true, checks: {} };
      try {
        const r = await fetch(`${env.SUPABASE_URL}/rest/v1/paints?select=id&limit=1`, {
          headers: { apikey: env.SUPABASE_ANON_KEY, authorization: `Bearer ${env.SUPABASE_ANON_KEY}` },
          cf: { cacheTtl: 0 },
        });
        out.checks.database = r.ok ? "ok" : `ng(${r.status})`;
        if (!r.ok) { out.ok = false; console.error("healthz: データベースの応答が異常", r.status); }
      } catch (e) {
        out.checks.database = "ng(unreachable)"; out.ok = false;
        console.error("healthz: データベースに到達できない", e);
      }
      try {
        // 配信元は Worker 同梱になったので、外部ではなく自分のアセットを確認する
        const r = await fetchOrigin(env, "/index.html");
        out.checks.origin = r.ok ? "ok" : `ng(${r.status})`;
        if (!r.ok) { out.ok = false; console.error("healthz: 配信元の応答が異常", r.status); }
      } catch (e) {
        out.checks.origin = "ng(unreachable)"; out.ok = false;
        console.error("healthz: 配信元に到達できない", e);
      }
      const body = JSON.stringify(out);
      const status = out.ok ? 200 : 503;
      healthCache = { at: now, body, status };
      return new Response(body, {
        status,
        headers: { ...SECURITY_HEADERS, "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store", "x-health-cache": "miss" },
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

    // ここから先は「静的ファイルをそのまま配る」だけの経路。
    // 読み取り(GET)と見出しだけ取得(HEAD)以外の用事は存在しないので、POST/PUT/DELETE等は
    // 上流に一切通さず405で断る（無駄な経路を閉じ、上流への書き込み風リクエストを届かせない）。
    // ※/healthz・/sitemap.xml・/robots.txt・/r/:id は上で処理済みなので、この制限の影響を受けない。
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        // Allowヘッダは「ではどの方法なら良いのか」を相手に伝えるHTTPの作法（405では必須）
        headers: { ...SECURITY_HEADERS, allow: "GET, HEAD", "cache-control": "no-store" },
      });
    }

    // それ以外は GitHub Pages の中身を配信（raw は text/plain で返るので拡張子から content-type を再設定）
    const reqPath = path === "/" ? "/index.html" : path;
    let originRes;
    try {
      originRes = await fetchOrigin(env, reqPath, url.search);
    } catch (e) {
      console.error("static proxy: 配信元の取得に失敗", reqPath, e);
      return new Response("Service Unavailable", { status: 503, headers: { ...SECURITY_HEADERS, "cache-control": "no-store" } });
    }
    if (originRes.status === 404) return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });
    // 404以外のエラー(403/429/5xx等)は本文を素通ししない。
    // 配信元は raw.githubusercontent.com で、アクセス集中時に 403/429 を返すことがある。
    // これをそのまま max-age=300 で返すと「バズった瞬間にGitHubのエラー文が5分間貼り付く」ため、
    // 必ず 503 + no-store にしてリロードで復帰できるようにする。
    if (originRes.status >= 400) {
      console.error("static proxy: 配信元の応答が異常", originRes.status, reqPath);
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
