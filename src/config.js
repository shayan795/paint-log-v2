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
  var PROD = {
    SUPABASE_URL: "https://zlkbaojclitlxshpxwpr.supabase.co",
    SUPABASE_ANON_KEY: "sb_publishable_ZMaz3JjPfU0q_pq7Y9QwSQ_QimbhfgX",
  };

  // 開発用DB（作ったらここに貼る）。未設定は null のまま。
  // 例: var DEV = { SUPABASE_URL: "https://xxxx.supabase.co", SUPABASE_ANON_KEY: "sb_publishable_xxx" };
  var DEV = null;

  var host = (location && location.hostname) || "";
  var isLocal = host === "localhost" || host === "127.0.0.1" || host === "0.0.0.0" || host === "";
  window.PAINTLOG_CONFIG = (isLocal && DEV) ? DEV : PROD;
})();
