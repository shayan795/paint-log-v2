#!/usr/bin/env node
/**
 * 資産(src/config.js / src/methods.js)の「版」をHTMLに書き込む
 * ----------------------------------------------------------------------------
 *   使い方:
 *     node scripts/bump_asset_version.mjs           … HTMLを書き換える（push前に実行）
 *     node scripts/bump_asset_version.mjs --check   … ズレていたら失敗(終了コード1)。書き換えない
 *
 * ----------------------------------------------------------------------------
 * ★なぜこのスクリプトが要るのか（BOMBS B-003）
 *
 *   デプロイ直後の数分間、「新しいHTML＋古いJS」が混ざる時間帯があった。
 *   HTMLとJSは別々のファイルで、それぞれ別々のタイミングでキャッシュが切れるため、
 *   HTMLだけ新しくなって中身のJSは古いまま、という状態が普通に起きる。
 *   これは「何も変えていないのに動かない」謎の不具合の温床で、実際に 2026-07-28 の
 *   Supabaseライブラリ自前配信の切替でヒヤリとした。
 *
 *   対策は単純で、JSのURLに版を付けること。中身が変われば版が変わり、URLが変わり、
 *   ブラウザとCloudflareは「知らないファイル」として必ず取りに行く。
 *
 *   ただし版を人手で書き換える運用は必ず忘れる。だから機械にやらせる＝このスクリプト。
 *
 * ----------------------------------------------------------------------------
 * ★なぜ「ファイル名に版」ではなく「?v=」なのか（実測して決めた）
 *
 *   - ファイル名方式 (src/config.v2.js) は全キャッシュを確実に外せるが、
 *     古いHTMLがまだ配られている数分間に "古い名前" が消えて404になる。
 *     config.js が404になると設定が読めず、サイトが丸ごと動かなくなる。危険すぎる。
 *   - ?v= 方式はパスが常に存在するので、その事故が原理的に起きない。
 *     配信元(GitHub Pages)が未知のクエリを200で返すことは curl で確認済み。
 *
 *   ※限界も正直に記録しておく: GitHub Pages(Fastly)はキャッシュの見分けに ?v= を
 *     使わない（別の ?v= を投げても同じキャッシュが返り age が共通で増えることを実測）。
 *     つまりPages側には最大10分ほど古い中身が残りうる。ブラウザとCloudflareの層は
 *     ?v= で確実に外れるので大半の事故は消えるが、残りは「検出」で拾う方針にした。
 *
 * ----------------------------------------------------------------------------
 * ★版の決め方
 *
 *   版 = src/config.js と src/methods.js の中身から計算したハッシュの先頭8桁。
 *   中身が変わった時だけ版が変わる（無駄なキャッシュ外しをしない）。
 *   何度実行しても同じ結果になる（＝安心して毎回流せる）。
 *
 * ★HTMLに一緒に埋める「指紋」について
 *
 *   版だけをHTMLに書いても、ブラウザ側では「今読み込まれたJSが本当にその版か」を
 *   確かめられない。そこで、JSを外から見たときの姿（設定のキー名・塗装方法のslug）を
 *   一緒に埋めておき、ブラウザ側で突き合わせる。
 *   src/*.js を一切書き換えずに検出できるのが利点。
 *   （HTMLが期待する項目が読み込まれたJSに無ければ、それが版ズレの証拠になる）
 */

import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const G = "\x1b[32m", R = "\x1b[31m", Y = "\x1b[33m", B = "\x1b[1m", X = "\x1b[0m";

/** 版の計算対象。ここに載っているファイルの中身が変われば版が変わる */
const ASSETS = ["src/config.js", "src/methods.js"];

/** 書き換え対象のHTML。どの資産を読んでいるかも書いておく（診断ページは config だけ） */
const TARGETS = [
  { file: "index.html",       uses: { config: true, methods: true  } },
  { file: "legacy.html",      uses: { config: true, methods: true  } },
  { file: "diagnostics.html", uses: { config: true, methods: false } },
];

const read = (rel) => readFileSync(join(ROOT, rel), "utf8");

/** 版＝資産の中身のハッシュ先頭8桁 */
function computeVersion() {
  const h = createHash("sha256");
  for (const a of ASSETS) { h.update(a); h.update("\0"); h.update(read(a)); h.update("\0"); }
  return h.digest("hex").slice(0, 8);
}

/**
 * 「指紋」＝JSを外から見たときの姿。
 * 実際にJSを動かして取り出すので、書き方を変えても中身が同じなら指紋は変わらない。
 */
function computeFingerprints() {
  // config.js は window と location を見る。本番と同じ条件（localhost以外）で動かす。
  const win = {};
  new Function("window", "location", read("src/config.js"))(win, { hostname: "plamo-paint.com" });
  const config = Object.keys(win.PAINTLOG_CONFIG || {}).sort().join(",");
  if (!config) throw new Error("src/config.js から PAINTLOG_CONFIG を取り出せませんでした");

  const methodsList = new Function(read("src/methods.js") + "\nreturn PAINT_METHODS;")();
  const methods = methodsList.map((m) => m.slug).join(",");
  if (!methods) throw new Error("src/methods.js から PAINT_METHODS を取り出せませんでした");

  return { config, methods };
}

/** ASSETVER:START〜END の中身を作り直す */
function buildBlock(version, fp, uses) {
  return `<!-- ASSETVER:START — 自動生成。手で編集しない（node scripts/bump_asset_version.mjs で更新される） -->
<script>
window.PAINTLOG_ASSET_EXPECT = {
  version: ${JSON.stringify(version)},
  config:  ${JSON.stringify(uses.config ? fp.config : "")},
  methods: ${JSON.stringify(uses.methods ? fp.methods : "")}
};
</script>
<!-- ASSETVER:END -->`;
}

const BLOCK_RE = /<!-- ASSETVER:START[\s\S]*?<!-- ASSETVER:END -->/;
// src="src/config.js" / src="/src/methods.js" のどちらの書き方にも当たるようにする。
// 既に ?v=... が付いていれば、それごと置き換える。
const URL_RE = /(<script\s+src="\/?src\/(?:config|methods)\.js)(\?v=[^"]*)?"/g;

/** 1ファイル分の「あるべき中身」を作る */
function rewrite(html, target, version, fp) {
  if (!BLOCK_RE.test(html)) {
    throw new Error(`${target.file} に ASSETVER:START〜END のブロックがありません（消してしまった場合は index.html を参考に戻すこと）`);
  }
  if (!URL_RE.test(html)) {
    URL_RE.lastIndex = 0;
    throw new Error(`${target.file} に src/config.js もしくは src/methods.js の読み込みが見つかりません`);
  }
  URL_RE.lastIndex = 0;
  return html
    .replace(URL_RE, (_m, head) => `${head}?v=${version}"`)
    .replace(BLOCK_RE, buildBlock(version, fp, target.uses));
}

export function bumpAssetVersion({ check = false } = {}) {
  const version = computeVersion();
  const fp = computeFingerprints();
  const stale = [];
  const changed = [];

  for (const target of TARGETS) {
    const before = read(target.file);
    const after = rewrite(before, target, version, fp);
    if (before === after) continue;
    if (check) { stale.push(target.file); continue; }
    writeFileSync(join(ROOT, target.file), after);
    changed.push(target.file);
  }

  return { version, fp, stale, changed };
}

// ---------------------------------------------------------------- コマンド実行
const isDirectRun = process.argv[1] && process.argv[1].endsWith("bump_asset_version.mjs");
if (isDirectRun) {
  const check = process.argv.includes("--check");
  let result;
  try {
    result = bumpAssetVersion({ check });
  } catch (e) {
    console.error(`\n${R}✗ 版の書き込みに失敗しました${X}\n  ${e.message}\n`);
    process.exit(1);
  }
  const { version, fp, stale, changed } = result;

  console.log(`\n${B}資産の版（?v=）${X}`);
  console.log(`  版        : ${G}${version}${X}   （src/config.js と src/methods.js の中身から計算）`);
  console.log(`  設定の指紋: ${fp.config}`);
  console.log(`  方法の指紋: ${fp.methods}`);

  if (check) {
    if (stale.length === 0) {
      console.log(`\n${G}✓ HTMLの版は最新です${X}\n`);
    } else {
      console.log(`\n${R}✗ HTMLの版が古いままです:${X} ${stale.join(", ")}`);
      console.log(`${Y}  → node scripts/bump_asset_version.mjs を実行してから push してください${X}\n`);
      process.exit(1);
    }
  } else if (changed.length === 0) {
    console.log(`\n${G}✓ 変更なし（すでに最新）${X}\n`);
  } else {
    console.log(`\n${G}✓ 書き換えました:${X} ${changed.join(", ")}\n`);
  }
}
