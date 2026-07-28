#!/usr/bin/env node
/**
 * 自動テストの実行（Worker編）
 *
 *   使い方:  node tests/run_worker_tests.mjs
 *
 *   何をするか:
 *     worker/src/worker.js に書かれている「判定だけをする関数」を取り出して実際に動かし、
 *     内部ファイルの遮断・HTMLエスケープ・画像URLの許可判定などが正しく効くか確かめます。
 *     Cloudflareへのデプロイも通信も不要で、ファイルを読むだけなので一瞬で終わります。
 *
 *   なぜ必要か:
 *     Workerはサイトの「入口」で、ここが緩むと
 *       ・未修正の脆弱性台帳(BOMBS.md)やDB定義(schema.sql)が誰でも読める
 *       ・OGPタグに細工が入り、共有カード経由でHTMLが壊れる／外部サイトの画像を踏まされる
 *     といった事故に直結します。これまでWorkerのテストは1本もありませんでした。
 *
 *   取り出し方について:
 *     worker.js は `export default` を含むため、そのまま import すると
 *     Cloudflare固有のAPIに依存して動きません。そこで「純粋な関数（外部に触らない関数）」
 *     だけを正規表現で抜き出し、new Function で評価しています。
 *     関数の書き方（先頭が行頭の function 宣言）を変えると取り出せなくなるので、
 *     その場合はここの正規表現も直してください。
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

let pass = 0, fail = 0;
const failures = [];

function check(area, name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) pass++;
  else { fail++; failures.push({ area, name, detail: `期待値=${JSON.stringify(expected)} / 実際=${JSON.stringify(actual)}` }); }
}
function truthy(area, name, cond, detail) {
  if (cond) pass++; else { fail++; failures.push({ area, name, detail: detail || "条件を満たしませんでした" }); }
}

// ------------------------------------------------------- worker.js から取り出す
const src = readFileSync(join(ROOT, "worker", "src", "worker.js"), "utf8");

// 行頭の `function 名前(` から、行頭の `}` までを1つの定義として取り出す
const PATTERNS = {
  isBlockedPath:        /^function isBlockedPath[\s\S]*?^\}/m,
  esc:                  /^function esc[\s\S]*?^\}/m,
  isAllowedImageOrigin: /^function isAllowedImageOrigin[\s\S]*?^\}/m,
  buildDescription:     /^function buildDescription[\s\S]*?^\}/m,
  UUID_RE:              /^const UUID_RE = .*$/m,
  // 本文SSR（レシピ本文をサーバー側でHTML化する部分）
  collectPaintRefs:     /^function collectPaintRefs[\s\S]*?^\}/m,
  buildPaintMaps:       /^function buildPaintMaps[\s\S]*?^\}/m,
  paintLabel:           /^function paintLabel[\s\S]*?^\}/m,
  buildRecipeBodyHtml:  /^function buildRecipeBodyHtml[\s\S]*?^\}/m,
};
const defs = [];
for (const [name, re] of Object.entries(PATTERNS)) {
  const m = src.match(re);
  if (!m) {
    console.error(`\n${R}worker.js から ${name} を取り出せませんでした。${X}`);
    console.error(`  worker.js の書き方が変わった可能性があります（tests/run_worker_tests.mjs の PATTERNS を直してください）。\n`);
    process.exit(1);
  }
  defs.push(m[0]);
}
const {
  isBlockedPath, esc, isAllowedImageOrigin, buildDescription, UUID_RE,
  collectPaintRefs, buildPaintMaps, paintLabel, buildRecipeBodyHtml,
} = new Function(`${defs.join("\n")}\nreturn { isBlockedPath, esc, isAllowedImageOrigin, buildDescription, UUID_RE, collectPaintRefs, buildPaintMaps, paintLabel, buildRecipeBodyHtml };`)();

// ---------------------------------------------------------- 内部ファイルの遮断
// GitHub Pages はリポジトリ全体を公開してしまうため、入口のWorkerで落とすのが唯一の防波堤。
check("内部ファイルの遮断", "脆弱性台帳(BOMBS.md)は配信しない", isBlockedPath("/BOMBS.md"), true);
check("内部ファイルの遮断", "大文字小文字を変えてもすり抜けられない", isBlockedPath("/bombs.MD"), true);
check("内部ファイルの遮断", "DB定義(supabase/schema.sql)は配信しない", isBlockedPath("/supabase/schema.sql"), true);
check("内部ファイルの遮断", "migrationsのSQLは配信しない", isBlockedPath("/migrations/007_audit_fixes.sql"), true);
check("内部ファイルの遮断", "testsフォルダは配信しない", isBlockedPath("/tests/run_front_tests.mjs"), true);
check("内部ファイルの遮断", "workerのソースは配信しない", isBlockedPath("/worker/src/worker.js"), true);
check("内部ファイルの遮断", "wrangler.tomlは配信しない", isBlockedPath("/worker/wrangler.toml"), true);
check("内部ファイルの遮断", "READMEは配信しない", isBlockedPath("/README.md"), true);
check("内部ファイルの遮断", "引き継ぎメモは配信しない", isBlockedPath("/CLAUDE引き継ぎ.md"), true);
check("内部ファイルの遮断", "XSSが残る旧参考ファイルは配信しない", isBlockedPath("/v1-reference.html"), true);
// ★URLエンコード等での回避（デコード処理を外すと、以下はすべて素通りしてしまう）
//   拡張子だけでも落ちる書き方（例: /BOMBS%2Emd）では「デコードが効いているか」を確かめられないため、
//   デコードして初めて遮断できる形をわざと選んでいる。
check("内部ファイルの遮断", "%2E（=.）で書いてもすり抜けられない", isBlockedPath("/%2Egit/config"), true);
check("内部ファイルの遮断", "%2F（=/）で書いてもすり抜けられない", isBlockedPath("/supabase%2Fschema"), true);
check("内部ファイルの遮断", "二重エンコード(%252E)でもすり抜けられない", isBlockedPath("/%252egit/config"), true);
check("内部ファイルの遮断", "バックスラッシュ区切りでもすり抜けられない", isBlockedPath("/supabase\\schema"), true);
check("内部ファイルの遮断", "スラッシュを重ねてもすり抜けられない", isBlockedPath("//migrations//001"), true);
check("内部ファイルの遮断", "パストラバーサル(..)は落とす", isBlockedPath("/%2E%2E/etc/passwd"), true);
check("内部ファイルの遮断", "%2Eで書いたBOMBS.mdも落とす", isBlockedPath("/BOMBS%2Emd"), true);
check("内部ファイルの遮断", "壊れた%エンコードでも落ちずに遮断できる", isBlockedPath("/BOMBS.md%"), true);
// 正常なファイルは通ること（遮断が効きすぎてサイトが死んでいないかの確認）
check("内部ファイルの遮断", "index.htmlは通す", isBlockedPath("/index.html"), false);
check("内部ファイルの遮断", "legacy.htmlは通す", isBlockedPath("/legacy.html"), false);
check("内部ファイルの遮断", "画像は通す", isBlockedPath("/assets/logo-mark.png"), false);
check("内部ファイルの遮断", "manifestは通す", isBlockedPath("/manifest.webmanifest"), false);
check("内部ファイルの遮断", "トップ(/)は通す", isBlockedPath("/"), false);
// ※/robots.txt は .txt なのでここでは true になるが、実際のルーティングでは
//   isBlockedPath より手前でWorkerが自前の内容を返すため問題ない（配信元の生ファイルは出さない）。
check("内部ファイルの遮断", "robots.txtの生ファイルは配信しない(本文はWorkerが手前で返す)", isBlockedPath("/robots.txt"), true);

// ---------------------------------------------------------------- HTMLエスケープ
// OGPタグに題名や制作者名を差し込むため、ここが緩むと共有カード経由でHTMLが壊れる。
check("HTMLエスケープ", "山かっこと引用符が実体参照になる", esc('<img src="x">'), "&lt;img src=&quot;x&quot;&gt;");
check("HTMLエスケープ", "シングルクォートも実体参照になる（属性の脱出を防ぐ）", esc("it's"), "it&#39;s");
check("HTMLエスケープ", "アンパサンドが実体参照になる", esc("a&b"), "a&amp;b");
truthy("HTMLエスケープ", "スクリプトタグがそのまま残らない", !esc("<script>alert(1)</script>").includes("<script>"));
truthy("HTMLエスケープ", 'og:content属性を閉じる細工が残らない', !esc('" /><meta content="').includes('"'));
check("HTMLエスケープ", "null・undefinedは空文字になる", [esc(null), esc(undefined)], ["", ""]);
check("HTMLエスケープ", "数値や0でも壊れない", [esc(0), esc(123)], ["0", "123"]);

// ------------------------------------------------------------ og:imageの許可判定
// 前方一致で判定すると supabase.co.evil.com のような外部ドメインを通してしまうため、
// 「オリジン完全一致」であることを確かめる。
const env = { SUPABASE_URL: "https://zlkbaojclitlxshpxwpr.supabase.co", SITE: "https://plamo-paint.com" };
check("og:imageの許可判定", "自分のStorage画像は許可", isAllowedImageOrigin(env.SUPABASE_URL + "/storage/v1/object/public/recipes/u/1.jpg", env), true);
check("og:imageの許可判定", "自サイトの画像は許可", isAllowedImageOrigin("https://plamo-paint.com/og-image.png", env), true);
check("og:imageの許可判定", "似せた別ドメインは不許可", isAllowedImageOrigin("https://zlkbaojclitlxshpxwpr.supabase.co.evil.com/a.jpg", env), false);
check("og:imageの許可判定", "サブドメインを足した別ドメインは不許可", isAllowedImageOrigin("https://evil.plamo-paint.com/a.jpg", env), false);
check("og:imageの許可判定", "外部サイトは不許可", isAllowedImageOrigin("https://evil.example.com/track.gif", env), false);
check("og:imageの許可判定", "http(暗号化なし)の自サイトも不許可（オリジンが違う）", isAllowedImageOrigin("http://plamo-paint.com/og-image.png", env), false);
check("og:imageの許可判定", "javascript: は不許可", isAllowedImageOrigin("javascript:alert(1)", env), false);
check("og:imageの許可判定", "相対パスは不許可", isAllowedImageOrigin("/assets/a.png", env), false);
check("og:imageの許可判定", "空・null・数値でも例外を投げず不許可", [isAllowedImageOrigin("", env), isAllowedImageOrigin(null, env), isAllowedImageOrigin(undefined, env), isAllowedImageOrigin(123, env)], [false, false, false, false]);

// ----------------------------------------------------------- OGP説明文の組み立て
const grid = {
  rows: [
    { part: "本体", cells: { a: { i: 10 }, b: { i: 10 }, c: { c: "自作グレー" } } },   // 塗料は2種（i:10 は重複）
    { part: "武器", cells: { a: { i: 11 }, b: null } },                                 // さらに1種
    { part: "   ",  cells: { a: { c: "自作グレー" } } },                                // 空白だけのpartは色グループに数えない
  ],
};
check("OGP説明文", "制作者・色グループ・塗料数がまとまる",
  buildDescription({ grid }, "テスト太郎"),
  "制作者 テスト太郎 / 2色グループ / 使用塗料 3種 — 塗装レシピ録で記録・共有");
check("OGP説明文", "制作者名が無ければ制作者を書かない",
  buildDescription({ grid }, ""),
  "2色グループ / 使用塗料 3種 — 塗装レシピ録で記録・共有");
check("OGP説明文", "中身が空なら既定の説明文になる（空の共有カードを作らない）",
  buildDescription({}, ""),
  "ガンプラ・模型の塗装レシピ — 塗装レシピ録で記録・共有");
check("OGP説明文", "recipeがnullでも落ちない", buildDescription(null, null),
  "ガンプラ・模型の塗装レシピ — 塗装レシピ録で記録・共有");
check("OGP説明文", "gridが壊れた形（rowsが配列でない）でも落ちない",
  buildDescription({ grid: { rows: "こわれた値" } }, ""),
  "ガンプラ・模型の塗装レシピ — 塗装レシピ録で記録・共有");
truthy("OGP説明文", "rowsにnullが混ざっていても落ちない",
  typeof buildDescription({ grid: { rows: [null, { cells: null }, { part: "本体" }] } }, "") === "string");
truthy("OGP説明文", "制作者名にHTMLが入っていてもescを通せば無害化できる",
  !esc(buildDescription({ grid: {} }, '<img src=x onerror=alert(1)>')).includes("<img"));

// ------------------------------------------------------------- レシピIDの形の検証
// 形の違うIDでSupabaseへ問い合わせさせない（無料枠の消費・障害の誘発を防ぐ）ための門番。
check("レシピIDの検証", "正しいUUIDは通る", UUID_RE.test("11111111-2222-3333-4444-555555555555"), true);
check("レシピIDの検証", "大文字のUUIDも通る", UUID_RE.test("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"), true);
check("レシピIDの検証", "短いIDは通さない", UUID_RE.test("1111-2222"), false);
check("レシピIDの検証", "16進以外の文字は通さない", UUID_RE.test("zzzzzzzz-2222-3333-4444-555555555555"), false);
check("レシピIDの検証", "前後に文字を足したものは通さない", UUID_RE.test("x11111111-2222-3333-4444-555555555555x"), false);
check("レシピIDの検証", "改行を足したものは通さない（$のすり抜け防止）", UUID_RE.test("11111111-2222-3333-4444-555555555555\n"), false);
check("レシピIDの検証", "SQL/URLの細工を混ぜたものは通さない", UUID_RE.test("11111111-2222-3333-4444-555555555555&select=*"), false);
check("レシピIDの検証", "空文字は通さない", UUID_RE.test(""), false);

// ================================================================ 本文のSSR
// /r/:id はレシピ本文をサーバー側でHTMLにして生HTMLに入れる（入れないと検索エンジンから
// 見て「中身の無いページ」になる）。ここが緩むと、レシピ名や塗料名に細工を書いた投稿だけで
// 閲覧ページにHTMLを注入できてしまう＝過去に事故を起こした経路そのもの。

// --- 参照の収集（どの塗料を引けばよいか） ---
const ssrGrid = {
  kit: "RX-78-2 ガンダム",
  author: "テスト太郎",
  memo: "缶スプレーで塗装",
  procs: [{ id: "q1", name: "サフ" }, { id: "q2", name: "本塗装" }, { id: "q3", name: "空の工程" }],
  rows: [
    { part: "本体", cells: { q1: { id: "pt_aaaaaa111111", i: 0 }, q2: { i: 1 } }, comment: "2回塗り" },
    { part: "武器", cells: { q2: { c: "自作グレー" } } },
    { part: "",     cells: {} },                                  // 完全に空の行は出さない
  ],
};
check("本文SSR/参照の収集", "安定IDと並び順の両方を集める（重複は1回だけ）",
  collectPaintRefs(ssrGrid), { ids: ["pt_aaaaaa111111"], idxs: [0, 1] });
check("本文SSR/参照の収集", "形の違う値は信用せず捨てる（細工をURLに混ぜさせない）",
  collectPaintRefs({ rows: [{ cells: {
    a: { id: "pt_ZZZ" },                    // 16進以外
    b: { id: "pt_aaa" },                    // 短すぎる
    c: { id: "pt_aaaaaa,999" },             // クエリを割るための細工
    d: { i: -1 }, e: { i: 1.5 }, f: { i: "3" }, g: { i: NaN },
  } }] }), { ids: [], idxs: [] });
truthy("本文SSR/参照の収集", "gridが壊れていても例外を投げない",
  ["こわれた値", null, [], { rows: "x" }, { rows: [null, { cells: null }, { cells: [1, 2] }] }]
    .every(g => { try { collectPaintRefs(g); return true; } catch (_) { return false; } }));

// --- 塗料マスタの引き当て ---
const ssrMaps = buildPaintMaps([
  { id: "pt_aaaaaa111111", brand: "GSIクレオス Mr.カラー", code: "C1", name: "ホワイト", sort_order: 0 },
  { id: "pt_bbbbbb222222", brand: "タミヤ アクリル", code: "",   name: "フラットブラック", sort_order: 1 },
  { id: "pt_cccccc333333", brand: "細工", code: '"><script>alert(1)</script>', name: "$&", sort_order: 2 },
]);
check("本文SSR/塗料の引き当て", "安定IDで引ける（ブランド 型番 名称）",
  paintLabel({ id: "pt_aaaaaa111111" }, ssrMaps), "GSIクレオス Mr.カラー C1 ホワイト");
check("本文SSR/塗料の引き当て", "型番が空でも空白が二重にならない",
  paintLabel({ id: "pt_bbbbbb222222" }, ssrMaps), "タミヤ アクリル フラットブラック");
check("本文SSR/塗料の引き当て", "旧方式(並び順)でも引ける",
  paintLabel({ i: 1 }, ssrMaps), "タミヤ アクリル フラットブラック");
check("本文SSR/塗料の引き当て", "マスタに無ければ手入力の名前を使う",
  paintLabel({ id: "pt_ffffff999999", c: " 自作グレー " }, ssrMaps), "自作グレー");
check("本文SSR/塗料の引き当て", "何も指していなければ空文字（例外を投げない）",
  [paintLabel(null, ssrMaps), paintLabel({}, ssrMaps), paintLabel({ i: 999 }, null)], ["", "", ""]);

// --- 本文HTMLの組み立て ---
const ssrHtml = buildRecipeBodyHtml({ title: "旧タイトル", grid: ssrGrid }, ssrMaps, 20000);
truthy("本文SSR/本文の組み立て", "キット名が本文に出る", ssrHtml.includes("RX-78-2 ガンダム"));
truthy("本文SSR/本文の組み立て", "制作者名が本文に出る", ssrHtml.includes("テスト太郎"));
truthy("本文SSR/本文の組み立て", "メモが本文に出る", ssrHtml.includes("缶スプレーで塗装"));
truthy("本文SSR/本文の組み立て", "部位名が本文に出る", ssrHtml.includes("本体") && ssrHtml.includes("武器"));
truthy("本文SSR/本文の組み立て", "工程名が本文に出る", ssrHtml.includes("サフ") && ssrHtml.includes("本塗装"));
truthy("本文SSR/本文の組み立て", "マスタ塗料の名前が本文に出る", ssrHtml.includes("GSIクレオス Mr.カラー C1 ホワイト"));
truthy("本文SSR/本文の組み立て", "手入力の塗料名も本文に出る", ssrHtml.includes("自作グレー"));
truthy("本文SSR/本文の組み立て", "色グループのコメントも本文に出る", ssrHtml.includes("2回塗り"));
truthy("本文SSR/本文の組み立て", "どの部位にも塗料が無い工程の列は出さない", !ssrHtml.includes("空の工程"));
truthy("本文SSR/本文の組み立て", "JSが触る #viewMode / #viewTable には入れない（二重描画の防止）",
  !ssrHtml.includes('id="viewMode"') && !ssrHtml.includes('id="viewTable"'));
truthy("本文SSR/本文の組み立て", "自前のブロック(#__ssr_recipe)に入れ、JS起動後に自分で消える仕掛けがある",
  ssrHtml.includes('id="__ssr_recipe"') && ssrHtml.includes("removeChild"));

// --- 悪意ある入力（ここが過去に事故を起こした経路） ---
const evilGrid = {
  kit: '<script>alert(1)</script>',
  author: '"><img src=x onerror=alert(1)>',
  memo: "$&$'$`",
  procs: [{ id: "q1", name: '</table><script>alert(2)</script>' }],
  rows: [{ part: '<svg onload=alert(3)>', cells: { q1: { id: "pt_cccccc333333" } }, comment: '</div><script>x</script>' }],
};
const evilHtml = buildRecipeBodyHtml({ grid: evilGrid }, ssrMaps, 20000);
truthy("本文SSR/エスケープ", "レシピ名のscriptタグが生のまま出ない", !evilHtml.includes("<script>alert(1)"));
truthy("本文SSR/エスケープ", "工程名のscriptタグが生のまま出ない", !evilHtml.includes("<script>alert(2)"));
truthy("本文SSR/エスケープ", "部位名のタグが生のまま出ない", !evilHtml.includes("<svg onload"));
truthy("本文SSR/エスケープ", "コメントのタグが生のまま出ない", !evilHtml.includes("<script>x"));
truthy("本文SSR/エスケープ", "塗料名(マスタ側)のタグが生のまま出ない", !evilHtml.includes("<script>alert(1)</script>"));
truthy("本文SSR/エスケープ", "属性を閉じる細工(\")が生のまま出ない",
  !evilHtml.includes('"><img') && !evilHtml.includes('"><script'));
truthy("本文SSR/エスケープ", "エスケープ後も本文の入れ物(div/table)は壊れていない",
  evilHtml.startsWith('<div id="__ssr_recipe">') && evilHtml.includes("<table>"));
// ★注入は必ず replace の第2引数を「関数」にすること。文字列だと $& $' $` が特殊置換として
//   展開され、利用者の入力からページ本文が複製される（保存型XSSの入口）。
const fakePage = "<html><head></head><body><div id=app>APP</div></body></html>";
const injectedOk = fakePage.replace(/<body[^>]*>/i, m => m + evilHtml);
truthy("本文SSR/注入", "$&等を含む本文でも元のページが複製されない",
  injectedOk.split("APP").length === 2 && injectedOk.split("<body>").length === 2);
truthy("本文SSR/注入", "$&は文字として残る（特殊置換に化けない）", injectedOk.includes("$&amp;"));
truthy("本文SSR/注入", "本文はbodyの直後に入る", injectedOk.includes('<body><div id="__ssr_recipe">'));

// --- 壊れた入力・上限 ---
check("本文SSR/安全側の動作", "中身が何も無ければ本文を作らない（空の枠を出さない）",
  buildRecipeBodyHtml({ grid: {} }, ssrMaps, 20000), "");
check("本文SSR/安全側の動作", "recipeがnull/壊れた形でも例外を投げず空文字",
  [buildRecipeBodyHtml(null, null, 20000), buildRecipeBodyHtml({ grid: "こわれた値" }, ssrMaps, 20000),
   buildRecipeBodyHtml({ grid: { rows: "x", procs: 3 } }, ssrMaps, 20000)], ["", "", ""]);
truthy("本文SSR/安全側の動作", "rows/cellsにnullや配列が混ざっていても落ちない",
  typeof buildRecipeBodyHtml({ grid: { kit: "K", procs: [null, "x", { id: "q1", name: "サフ" }],
    rows: [null, [1], { cells: null }, { cells: [1] }, { part: "本体", cells: { q1: null } }] } }, ssrMaps, 20000) === "string");
const bigGrid = { kit: "大きなレシピ", procs: [{ id: "q1", name: "本塗装" }],
  rows: Array.from({ length: 400 }, (_, n) => ({ part: "部位" + n, cells: { q1: { id: "pt_aaaaaa111111" } } })) };
const bigHtml = buildRecipeBodyHtml({ grid: bigGrid }, ssrMaps, 2000);
truthy("本文SSR/安全側の動作", "上限を超える本文は打ち切る（応答が肥大化しない）", bigHtml.length < 12000);
truthy("本文SSR/安全側の動作", "打ち切っても表が閉じていて本文として成立する",
  bigHtml.includes("</tbody></table>") && bigHtml.includes("</article></div>"));
truthy("本文SSR/安全側の動作", "上限が十分なら全行が出る",
  buildRecipeBodyHtml({ grid: bigGrid }, ssrMaps, 200000).includes("部位399"));
// ★行数の上限だけでは足りない。gridは直APIで保存できるため、コメント1つに何MBも入れられる。
//   項目ごとの上限が外れると、1行のレシピで応答が数MBに膨らむ。
const hugeGrid = { kit: "あ".repeat(100000), author: "い".repeat(100000), memo: "う".repeat(100000),
  procs: [{ id: "q1", name: "え".repeat(100000) }],
  rows: [{ part: "お".repeat(100000), cells: { q1: { c: "か".repeat(100000) } }, comment: "き".repeat(100000) }] };
truthy("本文SSR/安全側の動作", "1項目が極端に長くても応答が肥大化しない（項目ごとの上限）",
  buildRecipeBodyHtml({ grid: hugeGrid }, ssrMaps, 20000).length < 12000);
truthy("本文SSR/安全側の動作", "刈り取っても本文の入れ物は壊れない",
  buildRecipeBodyHtml({ grid: hugeGrid }, ssrMaps, 20000).endsWith("</script>"));

// ---------------------------------------------------------------------- 出力
const byArea = new Map();
for (const f of failures) {
  if (!byArea.has(f.area)) byArea.set(f.area, []);
  byArea.get(f.area).push(f);
}
console.log(`\n${B}塗装レシピ録 — 自動テスト（Worker）${X}\n`);
if (failures.length === 0) {
  console.log(`${G}✓ すべて合格${X}（${pass} 件）\n`);
} else {
  for (const [area, list] of byArea) {
    console.log(`${R}✗${X} ${B}${area}${X}`);
    for (const f of list) {
      console.log(`    ${R}✗ ${f.name}${X}`);
      console.log(`      ${Y}${f.detail}${X}`);
    }
  }
  console.log(`\n${B}結果${X}: 合計 ${pass + fail} 件 / ${G}合格 ${pass}${X} / ${R}不合格 ${fail}${X}\n`);
  process.exit(1);
}
