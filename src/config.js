// ============================================================================
// 塗装レシピ録 v2 — Supabase接続設定
// ----------------------------------------------------------------------------
// ここに Supabase の「URL」と「anonキー(公開用キー)」を貼る。
// 取得場所: Supabaseダッシュボード → Project Settings → API
//   - SUPABASE_URL  : "Project URL"
//   - SUPABASE_ANON_KEY : "Project API keys" の anon public キー
//
// anonキーはブラウザに出てOKな公開キー(秘密キーではない)。
// 本当の防御は anonキーの秘匿ではなく、データベース側のRLS(権限ルール)で行う。
// ※ secret(service_role)キーは絶対にここへ貼らないこと。
// ============================================================================
// ----------------------------------------------------------------------------
// dev / prod 分離（フェイルセーフ設計）
//  - PROD … 本番Supabase。既定。本番ドメイン等 localhost以外は「必ず」これを使う。
//  - DEV  … 開発用Supabase。2つ目の無料プロジェクトを作ったら URL/anonキー を貼る。
//           未設定(null)なら localhost でも PROD にフォールバック（＝現状と完全に同じ挙動）。
//  - 切替条件：localhost かつ DEV設定済みのときだけ DEV。それ以外は常に PROD。
//    → 本番が誤って別DB/空DBに繋ぐ経路を構造的に作らない。
// ----------------------------------------------------------------------------
(function () {
  // ★TURNSTILE_SITE_KEY について
  //   CAPTCHA（人間かどうかの確認）に Cloudflare Turnstile を使う。ここに入れるのは
  //   「サイトキー」＝ブラウザに出してよい公開用の値（もう一方の「シークレットキー」は
  //   Supabaseの管理画面にだけ貼る。ここには絶対に書かない）。
  //   null の間はCAPTCHAの仕組み自体が動かない＝これまでと完全に同じ挙動になる。
  //
  //   ⚠️ 反映の順序を必ず守ること:
  //     ①ここにサイトキーを入れて push（サイト側が合格証を送れる状態にする）
  //     ②反映を確認してから、Supabase管理画面でCAPTCHAを有効にする
  //   逆順にすると、合格証を送れないためログインも新規登録も全て失敗する。
  var PROD = {
    SUPABASE_URL: "https://zlkbaojclitlxshpxwpr.supabase.co",
    SUPABASE_ANON_KEY: "sb_publishable_ZMaz3JjPfU0q_pq7Y9QwSQ_QimbhfgX",
    TURNSTILE_SITE_KEY: null,
  };

  // 開発用DB（2つ目の無料Supabase「plamo-paint-dev」）。localhostのみここに繋ぐ。
  // 公開キーなのでコミットしてOK（本番はフェイルセーフで常にPRODを使う）。
  var DEV = {
    SUPABASE_URL: "https://sazcssakhqiznochuprz.supabase.co",
    SUPABASE_ANON_KEY: "sb_publishable_AIm5N2YaD7PNKgJDpzTyFg_JIaxWvJP",
    // 開発用。Turnstileの「常に合格する」テスト用サイトキー（Cloudflare公式が公開している値）。
    // localhostで登録・ログインの動作確認をするときに使う。本物の鍵は要らない。
    TURNSTILE_SITE_KEY: "1x00000000000000000000AA",
  };

  var host = (location && location.hostname) || "";
  var isLocal = host === "localhost" || host === "127.0.0.1" || host === "0.0.0.0" || host === "";
  window.PAINTLOG_CONFIG = (isLocal && DEV) ? DEV : PROD;
})();
