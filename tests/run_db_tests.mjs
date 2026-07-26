#!/usr/bin/env node
/**
 * 自動テストの実行（データベース編）
 *
 *   使い方:  node tests/run_db_tests.mjs
 *
 *   何をするか:
 *     開発用DB(dev)に入れてあるテストを全部走らせて、結果を日本語で表示します。
 *     本番のデータベースには一切触れません（接続先はdev固定）。
 *
 *   前提:
 *     dev DBに tests スキーマ（土台とテスト本体）が入っていること。
 *     入れ直したいときは tests/db/*.sql を Supabase の SQL Editor で実行してください。
 */

const DEV_URL = "https://sazcssakhqiznochuprz.supabase.co";
const DEV_KEY = "sb_publishable_AIm5N2YaD7PNKgJDpzTyFg_JIaxWvJP";

// 本番に向かないよう二重で確認する（事故防止）
if (!DEV_URL.includes("sazcssakhqiznochuprz")) {
  console.error("接続先が開発用DBではありません。中止します。");
  process.exit(1);
}

const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

async function rpc(name, args = {}) {
  const res = await fetch(`${DEV_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: DEV_KEY,
      Authorization: `Bearer ${DEV_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${name}: HTTP ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

(async () => {
  console.log(`\n${B}塗装レシピ録 — 自動テスト（データベース）${X}`);
  console.log(`接続先: 開発用DB（本番には触れません）\n`);

  let rows;
  try {
    rows = await rpc("run_all_tests");
  } catch (e) {
    console.error(`${R}テストを実行できませんでした${X}`);
    console.error(`  ${e.message}`);
    console.error(`\n  ヒント: dev DBに tests スキーマが入っていない可能性があります。`);
    console.error(`  tests/db/*.sql を Supabase の SQL Editor で実行してください。`);
    process.exit(1);
  }

  const byArea = new Map();
  for (const r of rows) {
    if (!byArea.has(r.area)) byArea.set(r.area, []);
    byArea.get(r.area).push(r);
  }

  let pass = 0, fail = 0;
  for (const [area, list] of byArea) {
    const ng = list.filter((r) => !r.ok);
    pass += list.length - ng.length;
    fail += ng.length;
    const mark = ng.length ? `${R}✗${X}` : `${G}✓${X}`;
    console.log(`${mark} ${B}${area}${X}  ${list.length - ng.length}/${list.length} 合格`);
    for (const r of ng) {
      console.log(`    ${R}✗ ${r.name}${X}`);
      if (r.detail) console.log(`      ${Y}${r.detail}${X}`);
    }
  }

  console.log(`\n${B}結果${X}: 合計 ${pass + fail} 件 / ${G}合格 ${pass}${X} / ${fail ? R : ""}不合格 ${fail}${X}`);
  if (fail) {
    console.log(`\n${R}不合格があります。${X}上に出ている「✗」の内容を確認してください。`);
    console.log(`変更を加えた直後なら、その変更が原因の可能性が高いです。`);
    process.exit(1);
  }
  console.log(`\n${G}すべて合格しました。${X}\n`);
})();
