#!/usr/bin/env node
/**
 * 自動テスト（塗料の参照編）
 *
 *   使い方:  node tests/run_paint_tests.mjs
 *
 *   何をするか:
 *     レシピの1マスが「どの塗料か」を指す仕組みを、legacy.html から取り出して実際に動かす。
 *
 *   なぜ必要か:
 *     以前はマスが「塗料リストの何番目か」で塗料を指していた。
 *     この方式だと、リストの先頭に1色足すだけで、過去の全レシピの色が1つずつズレる。
 *     しかもエラーが出ないので誰も気づかない（＝一番たちの悪い壊れ方）。
 *     いまは「塗料そのものに付けた変わらない番号(安定ID)」で指すようにしてある。
 *     ここが壊れると同じ事故が再発するので、機械的に確かめる。
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

let pass = 0;
const failures = [];
function check(area, name, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) pass++;
  else failures.push({ area, name, detail: `期待値=${JSON.stringify(expected)} / 実際=${JSON.stringify(actual)}` });
}
function truthy(area, name, cond, detail) {
  if (cond) pass++; else failures.push({ area, name, detail: detail || "条件を満たしませんでした" });
}

// ---------------------------------------------------------------- 取り出し
const src = readFileSync(join(ROOT, "legacy.html"), "utf8");
function grab(re, what) {
  const m = src.match(re);
  if (!m) throw new Error(`legacy.html から${what}を取り出せませんでした（書き方を変えたなら、このテストの取り出し方も直すこと）`);
  return m[0];
}
const paintsDef  = grab(/const PAINTS = \[[\s\S]*?\n\];/, "塗料リスト");
const byIdDef    = grab(/const PAINT_BY_ID = \(function\(\)\{[\s\S]*?\}\)\(\);/, "ID索引");
const paintOfDef = grab(/function paintOf\(c\)\{[\s\S]*?\n\}/, "paintOf");
const hasRefDef  = grab(/function hasPaintRef\(c\)\{.*?\}/, "hasPaintRef");
const keyDef     = grab(/function paintKey\(c\)\{.*?\}/, "paintKey");
const refDef     = grab(/function paintRef\(i\)\{[\s\S]*?\n\}/, "paintRef");

const warnings = [];
const { PAINTS, paintOf, hasPaintRef, paintKey, paintRef, PAINT_BY_ID } = new Function(
  "console",
  `${paintsDef}\n${byIdDef}\n${paintOfDef}\n${hasRefDef}\n${keyDef}\n${refDef}
   return { PAINTS, paintOf, hasPaintRef, paintKey, paintRef, PAINT_BY_ID };`
)({ warn: (...a) => warnings.push(a.join(" ")) });

// ---------------------------------------------------------------- 塗料リスト本体
check("塗料リスト", "512色ある", PAINTS.length, 512);
truthy("塗料リスト", "全色に安定IDが付いている", PAINTS.every(p => /^pt_[0-9a-f]{6,32}$/.test(p[4] || "")),
  `IDが無い/形が違う色: ${PAINTS.filter(p => !/^pt_[0-9a-f]{6,32}$/.test(p[4] || "")).length}件`);
truthy("塗料リスト", "安定IDに重複が無い", new Set(PAINTS.map(p => p[4])).size === PAINTS.length,
  `重複: ${PAINTS.length - new Set(PAINTS.map(p => p[4])).size}件`);
// 色は #RRGGBB と、3桁の省略形 #RGB の両方を許す（#222 のような書き方もCSSとして正しい）
truthy("塗料リスト", "全色に名前と色がある",
  PAINTS.every(p => p[2] && /^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/.test(p[3] || "")),
  `満たさない色: ${JSON.stringify(PAINTS.filter(p => !p[2] || !/^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/.test(p[3] || "")))}`);

// ---------------------------------------------------------------- 参照解決
// 塗料が引けなかった場合に落ちず「null」として報告できるようにする。
// （途中で例外になると、そこから先のテストが1件も実行されず、何が壊れたのか分からなくなる）
const nameOf = p => (p && p[2]) || null;
const gold = PAINTS[8];                       // GSIクレオス C9 ゴールド
check("参照解決", "安定IDから正しい塗料が引ける", nameOf(paintOf({ id: gold[4] })), gold[2]);
check("参照解決", "古い書き方(配列の位置)でも引ける", nameOf(paintOf({ i: 8 })), gold[2]);
check("参照解決", "両方あるときは安定IDが優先される", nameOf(paintOf({ id: PAINTS[0][4], i: 8 })), PAINTS[0][2]);
check("参照解決", "手入力だけのマスは塗料なし", paintOf({ c: "自作の混色" }), null);
check("参照解決", "空・null・数値でも落ちない", [paintOf(null), paintOf(undefined), paintOf({}), paintOf(0)], [null, null, null, null]);
check("参照解決", "範囲外の位置は塗料なし", paintOf({ i: 99999 }), null);
check("参照解決", "存在しないIDは塗料なし", paintOf({ id: "pt_deadbeefdead" }), null);
truthy("参照解決", "存在しないIDのときは警告を残す（黙って消えない）",
  warnings.some(w => w.includes("pt_deadbeefdead")), `記録された警告: ${JSON.stringify(warnings)}`);
check("参照解決", "IDが見つからなくても位置があれば救済される", nameOf(paintOf({ id: "pt_deadbeefdead", i: 8 })), gold[2]);

// ★これが今回の本丸：リストの並びが変わっても安定IDなら同じ塗料を指し続ける
truthy("並び替え耐性", "リスト先頭に1色足しても安定IDは同じ塗料を指す", (function () {
  const shifted = [["ダミー", "X1", "テスト色", "#000000", "pt_dummy000000"]].concat(PAINTS);
  const byId = Object.create(null);
  shifted.forEach(p => { if (p[4]) byId[p[4]] = p; });
  return nameOf(byId[gold[4]]) === gold[2];
})());
truthy("並び替え耐性", "同じ条件で、古い書き方(位置)なら色がズレてしまう（＝直した意味がある）", (function () {
  const shifted = [["ダミー", "X1", "テスト色", "#000000", "pt_dummy000000"]].concat(PAINTS);
  return nameOf(shifted[8]) !== gold[2];   // ズレることを確認＝この移行が必要だった証拠
})());

// ---------------------------------------------------------------- 保存する形
check("保存する形", "塗料を選ぶと安定IDと位置の両方を書く", paintRef(8), { id: gold[4], i: 8 });
truthy("保存する形", "全色について書き出した形から元の塗料に戻れる",
  PAINTS.every((p, i) => paintOf(paintRef(i)) === p));

// ---------------------------------------------------------------- 判定まわり
check("判定", "マスタ塗料を指していると分かる", [hasPaintRef({ id: gold[4] }), hasPaintRef({ i: 8 })], [true, true]);
check("判定", "手入力だけのマスは指していないと分かる", hasPaintRef({ c: "混色" }), false);
check("判定", "空でも落ちない", [hasPaintRef(null), hasPaintRef(undefined)], [false, false]);
check("見分け札", "同じ塗料は同じ札になる", paintKey({ id: gold[4], i: 8 }), paintKey({ id: gold[4], i: 999 }));
truthy("見分け札", "違う塗料は違う札になる", paintKey({ id: PAINTS[0][4] }) !== paintKey({ id: PAINTS[1][4] }));
truthy("見分け札", "手入力は名前で見分ける", paintKey({ c: "混色A" }) !== paintKey({ c: "混色B" }));

// ---------------------------------------------------------------- 出力
const byArea = new Map();
for (const f of failures) {
  if (!byArea.has(f.area)) byArea.set(f.area, []);
  byArea.get(f.area).push(f);
}
console.log(`\n${B}塗装レシピ録 — 自動テスト（塗料の参照）${X}\n`);
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
  console.log(`\n${B}結果${X}: 合計 ${pass + failures.length} 件 / ${G}合格 ${pass}${X} / ${R}不合格 ${failures.length}${X}\n`);
  process.exit(1);
}
