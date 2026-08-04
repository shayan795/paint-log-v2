#!/usr/bin/env node
/**
 * バックアップが古くなっていないかを確認する
 *
 *   使い方:  node scripts/check_backups.mjs
 *
 * ★何のためか
 *   バックアップの一番怖い壊れ方は「止まったことに気づかない」こと。
 *   実際にこのサイトのデータベースのバックアップは、別リポジトリの
 *   GitHub Actions で毎日動いているが、**そのリポジトリに60日間なにも操作が無いと
 *   自動的に停止する**。しかも停止しても通知は出ない。
 *   写真のバックアップに至っては手動実行なので、忘れればそれきり。
 *
 *   そこで「最後に取れたのはいつか」を機械的に見て、古ければ赤で知らせる。
 *   オーナーが「やることある？」と聞いたときに必ず実行される（記憶に手順を書いてある）。
 *
 * ★このスクリプトは絶対に失敗しない（終了コードは常に0）。
 *   これが原因で他の作業が止まると本末転倒なため。
 */

import { readdirSync, existsSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PRIVATE = join(ROOT, "..", "塗装レシピ録-大型-private");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

const WARN_DAYS = 7;     // これを超えたら黄色
const BAD_DAYS  = 30;    // これを超えたら赤

/** YYYYMMDD 形式のフォルダ名から一番新しい日付を拾う */
function latestDateDir(dir) {
  if (!existsSync(dir)) return null;
  const days = readdirSync(dir).filter(n => /^\d{8}$/.test(n)).sort();
  return days.length ? days[days.length - 1] : null;
}

/** ファイル名に日付を含むもの（db-YYYYMMDD.json 等）から一番新しいものを拾う */
function latestDatedFile(dir) {
  if (!existsSync(dir)) return null;
  const hits = readdirSync(dir)
    .map(n => (n.match(/(\d{8})/) || [])[1])
    .filter(Boolean).sort();
  return hits.length ? hits[hits.length - 1] : null;
}

function daysAgo(yyyymmdd, today = new Date()) {
  if (!yyyymmdd) return null;
  const y = +yyyymmdd.slice(0, 4), m = +yyyymmdd.slice(4, 6), d = +yyyymmdd.slice(6, 8);
  const t = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  return Math.floor((t - Date.UTC(y, m - 1, d)) / 86400000);
}

export function checkBackups({ today = new Date(), quiet = false } = {}) {
  const items = [
    {
      name: "写真（利用者がアップした画像）",
      date: latestDateDir(join(ROOT, "backups", "storage")),
      how:  "bash scripts/backup_storage.sh",
      note: "手動実行。忘れると止まったままになる",
    },
    {
      name: "データベースの中身",
      date: latestDatedFile(join(PRIVATE, "db")),
      how:  "Claudeに「データベースのバックアップを取って」と言う",
      note: "別リポジトリの毎日の自動バックアップとは別に、手元にも控えを置く",
    },
  ];

  let worst = "ok";
  const lines = [];
  for (const it of items) {
    const d = daysAgo(it.date, today);
    let level = "ok";
    if (d === null) level = "bad";
    else if (d >= BAD_DAYS) level = "bad";
    else if (d >= WARN_DAYS) level = "warn";
    if (level === "bad") worst = "bad";
    else if (level === "warn" && worst === "ok") worst = "warn";
    lines.push({ ...it, days: d, level });
  }

  for (const l of lines) {
    if (l.level === "bad") {
      console.log("");
      console.log(`${R}${B}■ ${l.name} のバックアップが${l.date ? `${l.days}日前で古すぎます` : "見つかりません"}${X}`);
      console.log(`${R}   取り方: ${l.how}${X}`);
      console.log(`${R}   ${l.note}${X}`);
    } else if (l.level === "warn") {
      console.log("");
      console.log(`${Y}⚠ ${l.name} のバックアップが ${l.days}日前です（${WARN_DAYS}日を超えました）${X}`);
      console.log(`${Y}   取り方: ${l.how}${X}`);
    } else if (!quiet) {
      console.log(`${G}・${l.name}: ${l.days}日前（新しい）${X}`);
    }
  }

  // ★パス一覧そのものが古くなっていないかも見る。
  //   一覧が古いと「一覧に載っている分は全部取れた＝成功」と表示されるのに、
  //   その後に増えた画像は最初から対象外なので、静かに取り逃す。
  //   実際2026-08-04に、8日前の一覧のまま実行して新しい画像5件分がずれていた
  //   （うち5件は削除済みで失敗として検出できたが、新規追加分は失敗すら出ない）。
  try {
    const listPath = join(ROOT, "scripts", "storage_paths.local.txt");
    if (existsSync(listPath)) {
      const ageDays = Math.floor((today.getTime() - statSync(listPath).mtimeMs) / 86400000);
      if (ageDays >= WARN_DAYS) {
        console.log("");
        console.log(`${Y}⚠ 画像の一覧(storage_paths.local.txt)が ${ageDays}日前のものです${X}`);
        console.log(`${Y}   このまま取ると、その後に増えた画像を静かに取り逃します。${X}`);
        console.log(`${Y}   Claudeに「画像の一覧を最新にして」と言えば作り直します。${X}`);
        if (worst === "ok") worst = "warn";
      }
    } else {
      console.log(`${Y}⚠ 画像の一覧が見つかりません。公開分しかバックアップできていません。${X}`);
      if (worst === "ok") worst = "warn";
    }
  } catch (_) { /* 確認できなくても本体は止めない */ }

  // ★別リポジトリ側の自動バックアップは、ここからは確認できない。
  //   確認できないことを黙っていると「全部見えている」と誤解されるので明示する。
  if (!quiet) {
    console.log(`${Y}・別リポジトリ(plamo-paint-backups)の毎日の自動バックアップは、ここからは確認できません。${X}`);
    console.log(`${Y}  そのリポジトリに60日間なにも操作が無いと自動停止します（通知は出ません）。${X}`);
  }

  return { worst, lines };
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === join(process.argv[1]);
if (invokedDirectly) {
  const r = checkBackups();
  if (r.worst === "ok") console.log(`${G}→ バックアップは新しい状態です${X}`);
  process.exit(0);
}
