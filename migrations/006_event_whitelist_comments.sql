-- =====================================================================
-- 006_event_whitelist_comments.sql
--   #9 の一部: コメント系イベント4種を events の許可リストに追加する。
--   legacy.html 側は window.track → window.trackLegacy に修正済み（これが動くと
--   comment_posted 等が飛ぶが、001 の許可リストに無く弾かれるため、ここで追加する）。
--   001 を未適用の環境でも正しくなるよう「完全なリスト」で再定義する（NOT VALID）。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください。
-- =====================================================================

alter table public.events drop constraint if exists events_name_whitelist;
alter table public.events add  constraint events_name_whitelist check (
  event_name in (
    'page_view','view_recipe','search','click_paint','click_buy','recipe_shared',
    'settings_theme_changed','settings_notify_comments_toggled',
    'settings_email_change_requested','settings_email_change_failed',
    'settings_password_changed','settings_password_change_failed',
    -- ★ここから追加（コメント機能の計測）
    'comment_posted','comment_reply_posted','comment_liked','comment_unliked'
  )
) not valid;
