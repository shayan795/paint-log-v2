// v1 paints.js(配列形式)→ v2 assets/paints.js(安定ID付きオブジェクト)+ seed_paints.sql を生成
// 安定ID = ブランド+型番+名称の内容ハッシュ。配列位置に依存しないのでv1の {i:番号} の脆さを回避する。
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const v1 = readFileSync(ROOT + "site引き継ぎ/paints.js", "utf8");

// paints.js は `const PAINTS = [...]` を定義するだけ。安全に評価して取り出す。
const PAINTS = Function(v1 + "\nreturn PAINTS;")();

function stableId(brand, code, name) {
  const h = createHash("sha256").update(`${brand}${code}${name}`).digest("hex");
  return "pt_" + h.slice(0, 12);
}

const seen = new Map();
const rows = PAINTS.map(([brand, code, name, hex], i) => {
  let id = stableId(brand, code, name);
  if (seen.has(id)) { // 万一の衝突(同一brand/code/name)に連番を付けて回避
    const n = seen.get(id) + 1; seen.set(id, n); id = `${id}_${n}`;
  } else seen.set(id, 0);
  return { id, brand, code, name, hex, sort_order: i };
});

// --- assets/paints.js を出力 ---
const jsLines = rows.map(r =>
  `  { id:${JSON.stringify(r.id)}, brand:${JSON.stringify(r.brand)}, code:${JSON.stringify(r.code)}, name:${JSON.stringify(r.name)}, hex:${JSON.stringify(r.hex)} },`
);
const js = `/* ================================================================
   塗装レシピ録 v2 塗料マスターデータ(${rows.length}色)
   形式: { id, brand, code, name, hex }
   id = 内容ハッシュの安定ID(配列の位置が変わってもIDは不変)
   このファイルは supabase/gen_paints.mjs が site引き継ぎ/paints.js から生成。
   手で編集せず、元データを直して再生成すること。
================================================================ */
const PAINTS = [
${jsLines.join("\n")}
];
if (typeof window !== "undefined") window.PAINTS = PAINTS;
if (typeof module !== "undefined") module.exports = { PAINTS };
`;
writeFileSync(ROOT + "assets/paints.js", js);

// --- supabase/seed_paints.sql を出力 ---
const sq = s => "'" + String(s).replace(/'/g, "''") + "'";
const values = rows.map(r =>
  `  (${sq(r.id)}, ${sq(r.brand)}, ${sq(r.code)}, ${sq(r.name)}, ${sq(r.hex)}, ${r.sort_order})`
);
const sql = `-- 塗装レシピ録 v2 — 塗料マスタ初期データ(${rows.length}色)
-- 生成元: supabase/gen_paints.mjs(手編集しない)
-- 実行順: schema.sql を先に流してから このファイルを流す。
-- 何度流しても安全(同じIDは上書き)。

insert into public.paints (id, brand, code, name, hex, sort_order) values
${values.join(",\n")}
on conflict (id) do update
  set brand = excluded.brand,
      code  = excluded.code,
      name  = excluded.name,
      hex   = excluded.hex,
      sort_order = excluded.sort_order;
`;
writeFileSync(ROOT + "supabase/seed_paints.sql", sql);

console.log(`生成完了: ${rows.length}色`);
console.log(`空型番の数: ${rows.filter(r => !r.code).length}`);
console.log(`ID衝突回避した数: ${[...seen.values()].filter(v => v > 0).length}`);
