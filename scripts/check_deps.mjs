#!/usr/bin/env node
/**
 * 外部ライブラリの更新チェック
 *
 *   使い方:  node scripts/check_deps.mjs
 *
 *   何をするか:
 *     いま使っているSupabaseライブラリの版と、公式(npm)の最新版を比べます。
 *     さらに「いつ固定したか」の記録（vendor/pinned.json）と今日の日付を照合して、
 *     90日(約3か月)を過ぎていたら「検討してください」ではなく「実行してください」に切り替えます。
 *
 *   なぜ必要か:
 *     以前は「2で始まる最新版を毎回取ってくる」書き方だったため、平均4日に1度、
 *     誰にも知らされないままサイトの心臓部が別のプログラムに差し替わっていました。
 *     そこで版を固定して自分のサーバーに置きましたが、固定すると今度は
 *     「更新を忘れる」という逆の問題が出ます。
 *     ★このスクリプトは、その「忘れる」を防ぐためのものです。
 *       テスト実行時に自動で呼ばれるので、作業していれば必ず目に入ります。
 *
 *   ★日付は必ず vendor/pinned.json から読むこと。ファイルの更新日時(mtime)は使えません。
 *     gitで取得し直すと全ファイルの日時がその時刻に書き換わり、
 *     何年前に固定したものでも「今日固定したばかり」に見えてしまうためです。
 *
 *   ★このスクリプトは絶対に失敗しません（終了コードは常に0）。
 *     ネットが繋がらない場所で作業しているときに、これが原因でテストが止まると
 *     本来の目的（安心して開発する）を邪魔してしまうためです。
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

/** 固定の記録を読む */
export function readPinned() {
  const j = JSON.parse(readFileSync(join(ROOT, "vendor", "pinned.json"), "utf8"));
  return { packages: j.packages || [], reviewEveryDays: (j.policy && j.policy.reviewEveryDays) || 90 };
}

/** 実際にHTMLが読み込んでいる版（記録とHTMLがずれていないかの照合用） */
export function versionInHtml() {
  const html = readFileSync(join(ROOT, "index.html"), "utf8");
  const m = html.match(/\/vendor\/supabase-js-(\d+\.\d+\.\d+)\.js/);
  return m ? m[1] : null;
}

/** 数字を左から比べて新旧を判定する（2.110.9 と 2.9.0 を文字列比較すると誤るため） */
export function isNewer(a, b) {
  const pa = String(a).split(".").map(Number), pb = String(b).split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) > (pb[i] || 0)) return true;
    if ((pa[i] || 0) < (pb[i] || 0)) return false;
  }
  return false;
}

/** 記録された固定日から今日までの経過日数 */
export function daysSince(dateStr, today = new Date()) {
  const d = new Date(dateStr + "T00:00:00Z");
  if (isNaN(d.getTime())) return null;
  const t = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()));
  return Math.floor((t.getTime() - d.getTime()) / 86400000);
}

async function latestFromNpm(name) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);   // 遅いときは諦める（作業を止めない）
  try {
    const res = await fetch(`https://registry.npmjs.org/${name}/latest`, { signal: ctrl.signal });
    if (!res.ok) return null;
    return (await res.json()).version || null;
  } catch (_) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/**
 * 判定して結果を返す。
 * action は 3段階:
 *   "none"    … 何もしなくてよい
 *   "consider"… 新版が出ている（急ぎではない）
 *   "do"      … 90日を過ぎた。実行する
 */
export async function checkDeps({ quiet = false, offline = false, today = new Date() } = {}) {
  const { packages, reviewEveryDays } = readPinned();
  const results = [];

  for (const pkg of packages) {
    const days = daysSince(pkg.pinnedAt, today);
    const latest = offline ? null : await latestFromNpm(pkg.name);
    const hasNew = latest ? isNewer(latest, pkg.version) : false;
    const overdue = days !== null && days >= reviewEveryDays;
    results.push({
      name: pkg.name, current: pkg.version, latest, days, hasNew, overdue,
      action: overdue ? "do" : (hasNew ? "consider" : "none"),
    });
  }

  // HTMLと記録がずれていないか（版を上げたのに pinned.json を直し忘れた、の検出）
  const inHtml = versionInHtml();
  const sb = results.find(r => r.name === "@supabase/supabase-js");
  const mismatch = sb && inHtml && inHtml !== sb.current ? { html: inHtml, json: sb.current } : null;

  if (mismatch) {
    console.log("");
    console.log(`${R}${B}★ 記録と実物が食い違っています${X}`);
    console.log(`${R}   index.html が読んでいる版: ${mismatch.html}${X}`);
    console.log(`${R}   vendor/pinned.json の記録: ${mismatch.json}${X}`);
    console.log(`${R}   → pinned.json の version と pinnedAt を直してください（日付の判定がずれます）${X}`);
    console.log("");
  }

  for (const r of results) {
    if (r.action === "do") {
      console.log("");
      console.log(`${R}${B}■ ${r.name} を更新してください（${r.days}日経過・期限超過）${X}`);
      console.log(`${R}   固定した日: ${packages.find(p => p.name === r.name).pinnedAt}（${reviewEveryDays}日ごとに見直す約束）${X}`);
      console.log(`${R}   いま使用中: ${r.current}${r.latest ? `   →   公式の最新: ${r.latest}` : ""}${X}`);
      console.log(`${R}   ${r.hasNew ? "新版が出ています。" : "最新のままですが、"}手順どおり更新作業を行ってください。${X}`);
      console.log(`${R}   手順: README「§4.5 ライブラリを更新する」${X}`);
      console.log("");
    } else if (r.action === "consider") {
      console.log("");
      console.log(`${Y}${B}⚠ ${r.name} に新しい版が出ています${X}`);
      console.log(`${Y}   いま使用中: ${r.current}   →   公式の最新: ${r.latest}${X}`);
      console.log(`${Y}   固定してから ${r.days}日（${reviewEveryDays}日を過ぎたら実行に切り替わります）${X}`);
      console.log(`${Y}   急ぎではありません。手順: README「§4.5」${X}`);
      console.log("");
    } else if (!quiet) {
      if (r.latest === null) {
        console.log(`${Y}・${r.name}: 公式サイトに繋がらず新版の確認をスキップ（固定してから ${r.days}日）${X}`);
      } else {
        console.log(`${G}・${r.name}: 最新です（${r.current}・固定から ${r.days}日 / ${reviewEveryDays}日で見直し）${X}`);
      }
    }
  }

  return { results, mismatch, needsAttention: !!mismatch || results.some(r => r.action !== "none") };
}

// 直接実行されたときだけ動く（テストから読み込むときは動かさない）。
// ★パスに日本語が含まれると import.meta.url 側だけが %E5%A1%97... のように変換されるため、
//   文字列をそのまま比べると一致しない。必ず両方を実際のパスに戻してから比べること。
const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === join(process.argv[1]);
if (invokedDirectly) {
  const r = await checkDeps();
  if (!r.needsAttention) console.log(`${G}→ 対応が必要なものはありません${X}`);
  process.exit(0);   // ★何があっても0。これが原因で作業が止まらないようにするため
}
