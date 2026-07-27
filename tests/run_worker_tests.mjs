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
const { isBlockedPath, esc, isAllowedImageOrigin, buildDescription, UUID_RE } =
  new Function(`${defs.join("\n")}\nreturn { isBlockedPath, esc, isAllowedImageOrigin, buildDescription, UUID_RE };`)();

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
