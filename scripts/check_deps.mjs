#!/usr/bin/env node
/**
 * 外部ライブラリの更新チェック
 *
 *   使い方:  node scripts/check_deps.mjs
 *
 *   何をするか:
 *     いま使っているSupabaseライブラリの版と、公式(npm)の最新版を比べて、
 *     新しいものが出ていたら日本語で知らせます。
 *
 *   なぜ必要か:
 *     以前は「2で始まる最新版を毎回取ってくる」書き方だったため、平均4日に1度、
 *     誰にも知らされないままサイトの心臓部が別のプログラムに差し替わっていました。
 *     何も変えていないのに突然ログインできなくなる、という事故が起こりえます。
 *     そこで版を固定して自分のサーバーに置きました。
 *     ただし固定すると今度は「更新を忘れる」という逆の問題が出ます。
 *     ★このスクリプトは、その「忘れる」を防ぐためのものです。
 *       テスト実行時に自動で呼ばれるので、作業していれば必ず目に入ります。
 *
 *   ★重要: このスクリプトは絶対に失敗しません（終了コードは常に0）。
 *     ネットが繋がらない場所で作業しているときに、これが原因でテストが止まると
 *     本来の目的（安心して開発する）を邪魔してしまうためです。
 */

import { readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

// 「何日以上ほったらかしなら知らせるか」
const STALE_DAYS = 90;

/** index.html に書いてある読み込み先から、いま使っている版を読み取る（正本はHTML側。二重管理しない） */
export function pinnedVersion() {
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

async function latestFromNpm() {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);   // 遅いときは諦める（作業を止めない）
  try {
    const res = await fetch("https://registry.npmjs.org/@supabase/supabase-js/latest", { signal: ctrl.signal });
    if (!res.ok) return null;
    const j = await res.json();
    return j.version || null;
  } catch (_) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/** 固定しているファイルの最終更新日から「何日ほったらかしか」を出す */
function daysSincePinned(version) {
  try {
    const st = statSync(join(ROOT, "vendor", `supabase-js-${version}.js`));
    return Math.floor((Date.now() - st.mtimeMs) / 86400000);
  } catch (_) { return null; }
}

export async function checkDeps({ quiet = false } = {}) {
  const cur = pinnedVersion();
  if (!cur) {
    console.log(`${R}★ index.html からライブラリの版を読み取れませんでした${X}（読み込み先の書き方を変えた場合は scripts/check_deps.mjs も直すこと）`);
    return { ok: false };
  }
  const latest = await latestFromNpm();
  const days = daysSincePinned(cur);

  if (!latest) {
    if (!quiet) console.log(`${Y}・ライブラリの更新確認: 公式サイトに繋がらずスキップしました（ネット未接続かもしれません）${X}`);
    return { ok: true, skipped: true, current: cur };
  }

  if (isNewer(latest, cur)) {
    console.log("");
    console.log(`${Y}${B}⚠ Supabaseライブラリに新しい版が出ています${X}`);
    console.log(`${Y}   いま使用中: ${cur}   →   公式の最新: ${latest}${X}`);
    if (days !== null) console.log(`${Y}   最後に固定してから ${days} 日経過${X}`);
    console.log(`${Y}   更新手順: README の「§4.5 ライブラリを更新する」${X}`);
    console.log(`${Y}   ※急ぎではありません。ただし放置するとセキュリティ修正も入りません。${X}`);
    console.log("");
    return { ok: true, updateAvailable: true, current: cur, latest, days };
  }

  if (days !== null && days >= STALE_DAYS) {
    console.log(`${Y}・ライブラリは最新(${cur})ですが、固定してから ${days} 日経ちました。一度動作確認をしておくと安心です。${X}`);
  } else if (!quiet) {
    console.log(`${G}・ライブラリの更新確認: 最新です（${cur}）${X}`);
  }
  return { ok: true, updateAvailable: false, current: cur, latest, days };
}

// 直接実行されたときだけ動く（テストから読み込むときは動かさない）。
// ★パスに日本語が含まれると import.meta.url 側だけが %E5%A1%97... のように変換されるため、
//   文字列をそのまま比べると一致しない。必ず両方を実際のパスに戻してから比べること。
const invokedDirectly = process.argv[1]
  && fileURLToPath(import.meta.url) === join(process.argv[1]);
if (invokedDirectly) {
  const r = await checkDeps();
  console.log(r.updateAvailable ? "→ 更新版があります" : "");
  process.exit(0);   // ★何があっても0。これが原因で作業が止まらないようにするため
}
