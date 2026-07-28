#!/usr/bin/env node
/**
 * 配信用フォルダ(public/)を組み立てる
 *
 *   使い方:  node scripts/build_public.mjs
 *            （wrangler deploy の前に自動で走るので、普段は意識しなくてよい）
 *
 * ★なぜ「配らないものを除外する」ではなく「配るものだけを集める」のか
 *   除外方式は、書き忘れた瞬間に流出する。実際にこのリポジトリには
 *     backups/storage/... に利用者の写真40MBが置かれている（Git管理外だが手元には存在する）
 *   ため、1行書き忘れるだけで他人の写真が公開される事故になり得た。
 *   「これだけ配る」と書く方式なら、書き忘れても起きるのは「配信漏れ（すぐ気づく）」であって
 *   「流出（気づかない）」ではない。壊れ方が安全な側に倒れる。
 *
 * ★最後に self-check を必ず通す
 *   HTMLやmanifestが読み込んでいるファイルを実際に抽出し、public/ に揃っているかを確認する。
 *   足りなければ**エラーで止める**。配信漏れに気づかないままデプロイするのを防ぐため。
 */

import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, extname } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "public");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

// ---- 配信するもの（ここに書いたものだけが公開される） --------------------
// 1) リポジトリ直下の個別ファイル
const ROOT_FILES = [
  "index.html", "legacy.html", "help.html", "privacy.html", "terms.html",
  "course.html", "diagnostics.html", "goodbye.html",
  "robots.txt", "manifest.webmanifest", "sw.js",
  "favicon.ico", "og-image.png", "google-oauth-logo.png",
];
// 2) フォルダごと（直下のファイルのみ。サブフォルダは配信しない）
//    ★assets/_logo_backup_maroon（旧ロゴ）と assets/_logo_source（元データ）を
//      配信しないため、あえて「直下のみ」にしている。
const DIRS = [
  { dir: "src",    exts: [".js"] },
  { dir: "vendor", exts: [".js"] },                                   // pinned.json は配らない
  { dir: "assets", exts: [".png", ".ico", ".jpg", ".jpeg", ".svg", ".webp", ".js"] },
];

function copyFile(rel) {
  const from = join(ROOT, rel);
  if (!existsSync(from)) return null;
  const to = join(OUT, rel);
  mkdirSync(dirname(to), { recursive: true });
  writeFileSync(to, readFileSync(from));
  return statSync(from).size;
}

// ---- 組み立て ------------------------------------------------------------
rmSync(OUT, { recursive: true, force: true });   // 前回の残骸を必ず消す（消し忘れが配信され続けるのを防ぐ）
mkdirSync(OUT, { recursive: true });

const copied = [];
let bytes = 0;
const missing = [];

for (const f of ROOT_FILES) {
  const n = copyFile(f);
  if (n === null) missing.push(f); else { copied.push(f); bytes += n; }
}
for (const { dir, exts } of DIRS) {
  const abs = join(ROOT, dir);
  if (!existsSync(abs)) { missing.push(dir + "/"); continue; }
  for (const name of readdirSync(abs)) {
    const full = join(abs, name);
    if (!statSync(full).isFile()) continue;              // サブフォルダは無視（＝配信しない）
    if (!exts.includes(extname(name).toLowerCase())) continue;
    const rel = dir + "/" + name;
    const n = copyFile(rel);
    if (n !== null) { copied.push(rel); bytes += n; }
  }
}

// ---- self-check: 参照されているのに配信されていないものが無いか ----------
// HTML/manifest/sw.js が読み込んでいる自前ファイルを抽出して突き合わせる。
const scanTargets = copied.filter(f => /\.(html|webmanifest|js)$/.test(f));
const refs = new Set();
for (const f of scanTargets) {
  const src = readFileSync(join(OUT, f), "utf8");
  // src="..." href="..." "..." の中から、自前の相対/絶対パスらしきものを拾う
  const re = /["'(]\/?((?:assets|src|vendor)\/[A-Za-z0-9_.\-]+)/g;
  let m;
  while ((m = re.exec(src))) refs.add(m[1]);
}
const notShipped = [...refs].filter(r => !copied.includes(r));

// ---- 出力 ----------------------------------------------------------------
console.log(`\n${B}配信用フォルダを作りました${X}  public/`);
console.log(`  ファイル ${copied.length} 件 / ${(bytes / 1024).toFixed(0)} KB`);

if (missing.length) {
  console.log(`\n${Y}・元ファイルが見つからず飛ばしたもの:${X}`);
  for (const f of missing) console.log(`    ${f}`);
}
if (notShipped.length) {
  console.log(`\n${R}${B}★ 参照されているのに配信対象に入っていないファイルがあります${X}`);
  for (const f of notShipped) console.log(`${R}    ${f}${X}`);
  console.log(`${R}  → scripts/build_public.mjs の ROOT_FILES / DIRS に追加してください。`);
  console.log(`     このまま公開すると、その部分が読み込めずページが壊れます。${X}\n`);
  process.exit(1);            // ★ここで止める。配信漏れに気づかないまま公開させない
}
console.log(`${G}  参照されているファイルはすべて揃っています${X}\n`);
