#!/usr/bin/env node
/**
 * 自動テストの実行（画面まわり編）
 *
 *   使い方:  node tests/run_front_tests.mjs
 *
 *   何をするか:
 *     legacy.html / index.html に書かれている「安全のための関数」を実際に取り出して動かし、
 *     悪意ある入力を無害化できているかを確かめます。
 *     ブラウザもサーバーも不要で、ファイルを読むだけなので一瞬で終わります。
 *
 *   なぜ必要か:
 *     過去に「写真URLに細工を仕込むと、閲覧者のブラウザで悪意あるプログラムが動く」
 *     という重大な穴が実際にありました。ここが壊れると同じ事故が再発します。
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

/** HTMLから関数の定義を取り出して実行できる形にする */
function extractFn(file, pattern) {
  const src = readFileSync(join(ROOT, file), "utf8");
  const m = src.match(pattern);
  if (!m) throw new Error(`${file} から関数を取り出せませんでした: ${pattern}`);
  return m[0];
}

// ---------------------------------------------------------------- legacy.html
const legacy = readFileSync(join(ROOT, "legacy.html"), "utf8");
const escDef = legacy.match(/const esc = [\s\S]*?\[c\]\)\);/)[0];
const safePhotoDef = legacy.match(/const safePhoto = [\s\S]*?\n};/)[0];
const safeColorDef = legacy.match(/const safeColor = [\s\S]*?\n};/)[0];
const safePosDef = legacy.match(/const safePos = [\s\S]*?\n};/)[0];
// safePhoto は「自分のStorage由来か」を判定するため、設定と現在のオリジンを参照する。
// テストでは本番と同じ条件を用意する。
const SUPA = "https://zlkbaojclitlxshpxwpr.supabase.co";
const { esc, safePhoto, safeColor, safePos } = new Function(
  "window", "location", "URL",
  `${escDef}\n${safePhotoDef}\n${safeColorDef}\n${safePosDef}\nreturn { esc, safePhoto, safeColor, safePos };`
)({ PAINTLOG_CONFIG: { SUPABASE_URL: SUPA } }, { origin: "https://plamo-paint.com" }, URL);

// 写真URLの無害化（保存型XSS対策の要）
const STORAGE = SUPA + "/storage/v1/object/public/recipes/u/1_cover.jpg";
check("写真URLの無害化", "正規のStorage画像URLはそのまま通る", safePhoto(STORAGE), STORAGE);
check("写真URLの無害化", "canvasで作った画像(data:image)は通る", safePhoto("data:image/png;base64,AAA"), "data:image/png;base64,AAA");
check("写真URLの無害化", "属性を抜け出す細工は空になる", safePhoto('x" onerror="alert(1)'), "");
check("写真URLの無害化", "javascript: は空になる", safePhoto("javascript:alert(1)"), "");
check("写真URLの無害化", "JAVASCRIPT:（大文字）も空になる", safePhoto("JAVASCRIPT:alert(1)"), "");
check("写真URLの無害化", "http(暗号化なし)は通さない", safePhoto("http://example.com/a.jpg"), "");
check("写真URLの無害化", "外部サイトのHTTPS画像は通さない（閲覧者の追跡を防ぐ）", safePhoto("https://evil.example.com/track.jpg"), "");
check("写真URLの無害化", "似せた別ドメインも通さない", safePhoto("https://zlkbaojclitlxshpxwpr.supabase.co.evil.com/a.jpg"), "");
check("写真URLの無害化", "自サイト配信の画像は通る", safePhoto("https://plamo-paint.com/assets/logo-mark.png"), "https://plamo-paint.com/assets/logo-mark.png");
check("写真URLの無害化", "相対パスは通さない", safePhoto("/uid/1.png"), "");
check("写真URLの無害化", "data:text/html は通さない", safePhoto("data:text/html,<script>alert(1)</script>"), "");
check("写真URLの無害化", "空・null・数値でも壊れない", [safePhoto(""), safePhoto(null), safePhoto(undefined), safePhoto(123)], ["", "", "", ""]);
truthy("写真URLの無害化", "前後の空白は取り除かれる", safePhoto("  " + STORAGE + "  ") === STORAGE);

// HTMLエスケープ
check("HTMLエスケープ", "山かっこと引用符が実体参照になる", esc('<img src="x">'), "&lt;img src=&quot;x&quot;&gt;");
check("HTMLエスケープ", "アンパサンドが二重エスケープされない形で処理される", esc("a&b"), "a&amp;b");
truthy("HTMLエスケープ", "スクリプトタグを文字列化できる", !esc("<script>").includes("<script>"));

// CSS値の無害化
check("CSS色", "16進カラーはそのまま", safeColor("#E01E28"), "#E01E28");
check("CSS色", "rgb()はそのまま", safeColor("rgb(1,2,3)"), "rgb(1,2,3)");
check("CSS色", "色名はそのまま", safeColor("red"), "red");
check("CSS色", "CSS注入(閉じ括弧+別プロパティ)は既定値に落ちる", safeColor("#fff;background:url(javascript:alert(1))"), "#ddd");
check("CSS色", "expression等の悪意ある値は既定値に落ちる", safeColor("expression(alert(1))"), "#ddd");
check("CSS位置", "通常の値はそのまま", safePos("50% 30%"), "50% 30%");
check("CSS位置", "記号を含む注入は既定値に落ちる", safePos("50%;background:red"), "50% 50%");

// ---------------------------------------------------------------- index.html
const index = readFileSync(join(ROOT, "index.html"), "utf8");
const safeUrlDef = index.match(/var safeUrl = function\(u\)\{[\s\S]*?\};/)[0];
const thumbUrlDef = index.match(/var thumbUrl = function[\s\S]*?\n};/)[0];
const { safeUrl, thumbUrl } = new Function(`${safeUrlDef}\n${thumbUrlDef}\nreturn { safeUrl, thumbUrl };`)();

check("リンクURLの無害化", "httpsは通る", safeUrl("https://example.com"), "https://example.com");
check("リンクURLの無害化", "javascript:は空になる", safeUrl("javascript:alert(1)"), "");
check("リンクURLの無害化", "data:は空になる", safeUrl("data:text/html,x"), "");

// サムネイル（縦横比が崩れて特大表示になる不具合の再発防止）
const t = thumbUrl(STORAGE);
truthy("サムネイル", "変換用のURLに置き換わる", t.includes("/render/image/public/"), `実際=${t}`);
truthy("サムネイル", "幅と高さの両方を指定している（片方だけだと縦横比が崩れる）",
  t.includes("width=400") && t.includes("height=400"), `実際=${t}`);
truthy("サムネイル", "resize=contain がある（無いと拡大されて崩れる）", t.includes("resize=contain"), `実際=${t}`);
check("サムネイル", "Storage以外のURLは変換しない", thumbUrl("https://example.com/a.jpg"), "https://example.com/a.jpg");
check("サムネイル", "空でも壊れない", thumbUrl(""), "");

// ---------------------------------------------------------------- 出力
const byArea = new Map();
for (const f of failures) {
  if (!byArea.has(f.area)) byArea.set(f.area, []);
  byArea.get(f.area).push(f);
}
console.log(`\n${B}塗装レシピ録 — 自動テスト（画面まわり）${X}\n`);
if (failures.length === 0) {
  console.log(`${G}✓ すべて合格${X}（${pass} 件）\n`);
  // ★外部ライブラリの更新確認をここに置く理由:
  //   版を固定したことで「勝手に壊れる」事故は消えたが、代わりに「更新を忘れる」問題が出る。
  //   人の記憶に頼ると必ず抜けるので、開発中に必ず走るテストの最後にぶら下げて、
  //   何もしなくても目に入るようにしている。失敗しても本テストの結果には影響しない。
  try {
    const { checkDeps } = await import("../scripts/check_deps.mjs");
    await checkDeps({ quiet: true });
  } catch (_) { /* 確認できなくてもテストは成功のまま */ }
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
