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
const safeUrlDef = index.match(/var safeUrl = function\(u\)\{[\s\S]*?\n\};/)[0];
const safeThumbSrcDef = index.match(/var safeThumbSrc = function\(u\)\{[\s\S]*?\n\};/)[0];
const thumbUrlDef = index.match(/var thumbUrl = function[\s\S]*?\n};/)[0];
// window / location はブラウザ側にしか無いので、テストでは同等のものを与える
const stubs = `var window = { PAINTLOG_CONFIG: { SUPABASE_URL: "https://zlkbaojclitlxshpxwpr.supabase.co" } };
var location = { href: "https://plamo-paint.com/" };`;
const { safeUrl, thumbUrl, safeThumbSrc } = new Function(
  `${stubs}\n${safeUrlDef}\n${safeThumbSrcDef}\n${thumbUrlDef}\nreturn { safeUrl, thumbUrl, safeThumbSrc };`)();

check("リンクURLの無害化", "httpsは通る", safeUrl("https://example.com"), "https://example.com");
// 保存型CSS注入の再発防止。
// プロフィールのヘッダー画像URLは背景画像 background-image:url(...) にも使われるため、
// ")" や ";" が通ると url() を閉じて別のCSSを書き足せてしまう（画面を全面覆う等）。
check("CSS注入対策", "url()を閉じてCSSを継ぎ足す細工を拒否",
  safeUrl("https://evil.example.com/a.png);position:fixed;inset:0;background:red"), "");
check("CSS注入対策", "引用符入りを拒否", safeUrl('https://evil.example.com/a"x'), "");
check("CSS注入対策", "空白入りを拒否", safeUrl("https://evil.example.com/a .png"), "");
check("CSS注入対策", "波括弧入りを拒否", safeUrl("https://evil.example.com/a{}.png"), "");
check("CSS注入対策", "バッククォート入りを拒否", safeUrl("https://evil.example.com/a`x"), "");
truthy("CSS注入対策", "正常なURLは今までどおり通る",
  safeUrl("https://zlkbaojclitlxshpxwpr.supabase.co/storage/v1/object/public/profile/u/h.jpg") !== "");
check("リンクURLの無害化", "javascript:は空になる", safeUrl("javascript:alert(1)"), "");
check("リンクURLの無害化", "data:は空になる", safeUrl("data:text/html,x"), "");

// サムネイル（縦横比が崩れて特大表示になる不具合の再発防止）
const t = thumbUrl(STORAGE);
truthy("サムネイル", "変換用のURLに置き換わる", t.includes("/render/image/public/"), `実際=${t}`);
// 幅と高さは必ず両方・同じ値。片方だけだと縦横比が崩れて特大表示になる。
const tw = (t.match(/width=(\d+)/) || [])[1];
const th = (t.match(/height=(\d+)/) || [])[1];
truthy("サムネイル", "幅と高さの両方を同じ値で指定している（片方だけだと縦横比が崩れる）",
  !!tw && tw === th, `実際=${t}`);
// 400px固定だと、いまのスマホ（画面が2〜3倍細かい）で引き伸ばされてぼやける。
truthy("サムネイル", "画面の細かさに足りる大きさを取り寄せている（480px以上）",
  Number(tw) >= 480, `実際=${tw}px`);
truthy("サムネイル", "resize=contain がある（無いと拡大されて崩れる）", t.includes("resize=contain"), `実際=${t}`);
check("サムネイル", "空でも壊れない", thumbUrl(""), "");

// 一覧の表紙は「投稿者の写真」になった。表紙のURLは所有者がAPIで直接書ける列なので、
// 外部サーバーのURLを置かれると、トップページを開いた全員のIP・端末・時刻がそこへ送られる。
// 画像は普通に表示されるため、見ている側も運営側も異常に気づけない。
check("表紙の出どころ確認", "外部サーバーの画像は出さない",
  safeThumbSrc("https://evil.example.com/track.png"), "");
check("表紙の出どころ確認", "紛らわしい名前のドメインも出さない",
  safeThumbSrc("https://zlkbaojclitlxshpxwpr.supabase.co.evil.example.com/a.jpg"), "");
truthy("表紙の出どころ確認", "自分のStorageの画像は今までどおり通る",
  safeThumbSrc(STORAGE) === STORAGE, `実際=${safeThumbSrc(STORAGE)}`);
truthy("表紙の出どころ確認", "自サイトの画像も通る",
  safeThumbSrc("https://plamo-paint.com/og-image.png") !== "");
check("表紙の出どころ確認", "外部URLはサムネ変換にも渡さない",
  thumbUrl("https://evil.example.com/track.png"), "");

// ------------------------------------------------- アプリ内ブラウザの判定（index.html）
//
//   なぜ必要か:
//     Googleは「SNSアプリの中のブラウザ」でのログインを仕様として拒否する。
//     検出できないと、利用者は「Googleでログイン」を押して403で行き止まりになり、そのまま去る。
//     逆に検出しすぎる（誤検知）と、普通のSafari/Chromeの人に嘘の警告を出して離脱させる。
//     どちらも実害が大きいので、実在のUserAgentで両方向を固定する。
//
const inappSrc = index.match(/\/\* ==== BEGIN:INAPP ====[\s\S]*?\/\* ==== END:INAPP ==== \*\//);
if (!inappSrc) throw new Error("index.html から INAPP ブロックを取り出せませんでした");
/** UAと表示モードを差し替えて isInAppBrowser() を作る */
function makeIsInApp(ua, standalone) {
  const nav = { userAgent: ua };
  if (standalone) nav.standalone = true;
  const win = { matchMedia: () => ({ matches: !!standalone }) };
  return new Function("navigator", "window", `${inappSrc[0]}\nreturn isInAppBrowser;`)(nav, win);
}
const isInApp = (ua, standalone) => makeIsInApp(ua, standalone)();

// 実在するUserAgent（左: 名前 / 中: UA / 右: アプリ内ブラウザか）
const UA_TABLE = [
  // ---- アプリ内ブラウザ（true でなければならない）
  ["X(Twitter) iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/21F90 Twitter for iPhone/10.55", true],
  ["X(Twitter) Android ※アプリ名を名乗らない", "Mozilla/5.0 (Linux; Android 14; SM-S911B Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.6099.230 Mobile Safari/537.36", true],
  ["Instagram iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 334.0.0.42.95 (iPhone14,2; iOS 17_5_1; ja_JP; ja; scale=3.00; 1170x2532)", true],
  ["Instagram Android", "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/119.0.0.0 Mobile Safari/537.36 Instagram 334.0.0.42.95 Android", true],
  ["Facebook iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/460.0.0.32.107;FBBV/1234;FBDV/iPhone14,2]", true],
  ["Facebook Android", "Mozilla/5.0 (Linux; Android 14; SM-A536B Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/460.0.0.32.107;]", true],
  ["LINE iOS ※Safariを名乗る", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1 Line/14.6.1", true],
  ["LINE Android", "Mozilla/5.0 (Linux; Android 14; SO-51D Build/68.2.A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36 Line/14.6.1", true],
  ["Threads Android", "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36 Barcelona 340.0.0.35.109 Android", true],
  ["Threads iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Barcelona 340.0.0.35.109", true],
  ["TikTok Android", "Mozilla/5.0 (Linux; Android 13; V2172 Build/TP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/117.0.0.0 Mobile Safari/537.36 BytedanceWebview/d8a21c6", true],
  ["TikTok iOS(musical_ly)", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 musical_ly_33.5.0 JsSdk/2.0 NetType/WIFI", true],
  ["TikTok iOS(trill)", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 trill_320503 JsSdk/2.0 NetType/WIFI", true],
  ["Yahoo! JAPAN Android ※wv無し", "Mozilla/5.0 (Linux; Android 14; SC-53C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 YJApp-ANDROID jp.co.yahoo.android.yjtop/4.10.0", true],
  ["Yahoo! JAPAN iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 YJApp-IOS jp.co.yahoo.ios.yjtop/4.60.0", true],
  ["SmartNews iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 SmartNews/24.5.0", true],
  ["Discord Android", "Mozilla/5.0 (Linux; Android 14; Pixel 6 Build/AP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36 Discord/198.15", true],
  ["Slack iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1 Slack/24.05.20", true],
  ["KakaoTalk Android", "Mozilla/5.0 (Linux; Android 13; SM-G991N Build/TP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/119.0.0.0 Mobile Safari/537.36 KAKAOTALK 10.4.0", true],
  ["WeChat iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49(0x18003128) NetType/WIFI Language/ja", true],
  ["Snapchat iOS", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Snapchat/12.85.0.44 (like Safari/604.1)", true],
  ["汎用Android WebView", "Mozilla/5.0 (Linux; Android 11; M2101K6G Build/RKQ1; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Mobile Safari/537.36", true],
  ["汎用iOS WKWebView(Safariを名乗らない)", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", true],

  // ---- 通常のブラウザ（false でなければならない＝誤検知すると正常な利用者が離脱する）
  ["iOS Safari", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", false],
  ["SFSafariViewController(Safariと同じUA)", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", false],
  ["iOS Chrome", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/125.0.6422.80 Mobile/15E148 Safari/604.1", false],
  ["iOS Firefox", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/126.0 Mobile/15E148 Safari/605.1.15", false],
  ["iOS Edge", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 EdgiOS/125.0.2535.60 Mobile/15E148 Safari/604.1", false],
  ["iPad Safari", "Mozilla/5.0 (iPad; CPU OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", false],
  ["Android Chrome", "Mozilla/5.0 (Linux; Android 14; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.72 Mobile Safari/537.36", false],
  ["Android Firefox", "Mozilla/5.0 (Android 14; Mobile; rv:126.0) Gecko/126.0 Firefox/126.0", false],
  ["Android Edge", "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36 EdgA/125.0.2535.60", false],
  ["Samsung Internet", "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36", false],
  ["PC Chrome (Windows)", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", false],
  ["PC Safari (macOS)", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15", false],
  ["PC Firefox (Windows)", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0", false],
];
for (const [name, ua, want] of UA_TABLE) {
  check("アプリ内ブラウザ判定", `${name} は ${want ? "アプリ内" : "通常ブラウザ"}`, isInApp(ua, false), want);
}

// standalone（ブラウザUIが無い表示）でも検出が消えないこと。
// ★これが以前の最悪の静かな失敗。standalone を先に見て return false していたため、
//   アプリ内ブラウザが standalone と判定される端末では検出が丸ごと無効化されていた。
const UA_X_ANDROID = UA_TABLE[1][1], UA_INSTA_IOS = UA_TABLE[2][1], UA_LINE_IOS = UA_TABLE[6][1];
check("アプリ内ブラウザ判定", "standaloneでもX(Android WebView)はアプリ内のまま", isInApp(UA_X_ANDROID, true), true);
check("アプリ内ブラウザ判定", "standaloneでもInstagram iOSはアプリ内のまま", isInApp(UA_INSTA_IOS, true), true);
check("アプリ内ブラウザ判定", "standaloneでもLINE iOSはアプリ内のまま", isInApp(UA_LINE_IOS, true), true);
// 逆に、ホーム画面に追加した本物のPWA（Safariを名乗らないだけ）は誤検知しない
check("アプリ内ブラウザ判定", "ホーム画面追加のPWA(iOS)は通常扱い",
  isInApp("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", true), false);
check("アプリ内ブラウザ判定", "UAが空でも壊れず通常扱い", isInApp("", false), false);

// ------------------------------------------------- ログイン後の戻り先（オープンリダイレクト対策）
//
//   なぜ必要か:
//     受け取った戻り先をそのまま location に入れると、
//     /index.html?returnTo=//evil.com のURLを配るだけで
//     「うちのログイン画面から偽サイトへ送り込む」攻撃が成立してしまう。
//
const rtSrc = index.match(/\/\* ==== BEGIN:RETURNTO ====[\s\S]*?\/\* ==== END:RETURNTO ==== \*\//);
if (!rtSrc) throw new Error("index.html から RETURNTO ブロックを取り出せませんでした");
const { sanitizeReturnTo } = new Function(`${rtSrc[0]}\nreturn { sanitizeReturnTo };`)();

const UUID = "550e8400-e29b-41d4-a716-446655440000";
// 正常系（そのまま通す）
check("戻り先の検証", "レシピのパスは通る", sanitizeReturnTo("/r/" + UUID), "/r/" + UUID);
check("戻り先の検証", "大文字のIDも通る", sanitizeReturnTo("/r/" + UUID.toUpperCase()), "/r/" + UUID.toUpperCase());
check("戻り先の検証", "トップ（/）は通る", sanitizeReturnTo("/"), "/");
check("戻り先の検証", "/index.html は通る", sanitizeReturnTo("/index.html"), "/index.html");
check("戻り先の検証", "/legacy.html は通る", sanitizeReturnTo("/legacy.html"), "/legacy.html");
// 攻撃系（すべて空＝トップ扱いに落ちること）
check("戻り先の検証", "//evil.com は捨てる（別サイトへの誘導）", sanitizeReturnTo("//evil.com"), "");
check("戻り先の検証", "/\\evil.com は捨てる（ブラウザが//と解釈する）", sanitizeReturnTo("/\\evil.com"), "");
check("戻り先の検証", "https://evil.com は捨てる", sanitizeReturnTo("https://evil.com"), "");
check("戻り先の検証", "javascript: は捨てる", sanitizeReturnTo("javascript:alert(1)"), "");
check("戻り先の検証", "data: は捨てる", sanitizeReturnTo("data:text/html,<script>alert(1)</script>"), "");
check("戻り先の検証", "../ を使った上位移動は捨てる", sanitizeReturnTo("/../../etc/passwd"), "");
check("戻り先の検証", "改行やタブなど制御文字入りは捨てる", sanitizeReturnTo("/r/" + UUID + "\n"), "");
check("戻り先の検証", "先頭にNUL文字を挟んだ細工も捨てる", sanitizeReturnTo("\u0000//evil.com"), "");
check("戻り先の検証", "先頭に空白を挟んだ細工も捨てる", sanitizeReturnTo(" //evil.com"), "");
check("戻り先の検証", "先頭にタブを挟んだ細工も捨てる", sanitizeReturnTo("\t//evil.com"), "");
check("戻り先の検証", "長すぎる値は捨てる", sanitizeReturnTo("/r/" + "a".repeat(300)), "");
check("戻り先の検証", "IDの桁数が違うものは捨てる", sanitizeReturnTo("/r/1234"), "");
check("戻り先の検証", "クエリを付け足した細工は捨てる", sanitizeReturnTo("/r/" + UUID + "?next=//evil.com"), "");
check("戻り先の検証", "許可していないページは捨てる", sanitizeReturnTo("/admin.html"), "");
check("戻り先の検証", "空・null・数値でも壊れない",
  [sanitizeReturnTo(""), sanitizeReturnTo(null), sanitizeReturnTo(undefined), sanitizeReturnTo(123)], ["", "", "", ""]);

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
