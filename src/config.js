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
window.PAINTLOG_CONFIG = {
  SUPABASE_URL: "https://zlkbaojclitlxshpxwpr.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_ZMaz3JjPfU0q_pq7Y9QwSQ_QimbhfgX",
};
