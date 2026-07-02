-- =====================================================================
-- Phase 4: events テーブルの乱用対策
--   events は匿名 INSERT 可（events_insert = with check(true)）のため、
--   スパムで無料枠(500MB)を食い潰される/巨大JSONを送られるリスクがある。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください。
-- =====================================================================

-- 1) event_name ホワイトリスト（コード内で実際に使う12種）
--    ★新しいイベント名を track()/trackLegacy() に追加したら、必ずここにも追記すること。
--    既存行が違反していても失敗しないよう NOT VALID（新規INSERTには即効く）。
alter table public.events
  drop constraint if exists events_name_whitelist;
alter table public.events
  add constraint events_name_whitelist check (
    event_name in (
      'page_view','view_recipe','search','click_paint','click_buy','recipe_shared',
      'settings_theme_changed','settings_notify_comments_toggled',
      'settings_email_change_requested','settings_email_change_failed',
      'settings_password_changed','settings_password_change_failed'
    )
  ) not valid;

-- 2) properties のサイズ上限（巨大JSONでの容量食い潰し防止・約2KB）
alter table public.events
  drop constraint if exists events_props_size;
alter table public.events
  add constraint events_props_size check (pg_column_size(properties) < 2048) not valid;

-- 3) 保持期間：90日より古いイベントを削除する関数
create or replace function public.purge_old_events()
returns void language sql security definer set search_path = public as $$
  delete from public.events where occurred_at < now() - interval '90 days';
$$;

-- 4) 自動実行（任意）：pg_cron が使えるなら毎日 JST 3:00 に purge。
--    先に Database > Extensions で pg_cron を有効化してから、以下を実行：
--    select cron.schedule('purge-old-events', '0 18 * * *', $$ select public.purge_old_events(); $$);
--    pg_cron を使わない場合は、月1回など手動で「select public.purge_old_events();」を実行すればよい。

-- 参考：将来的なレート制限は Postgres 単体では困難。必要になったら Cloudflare WAF
--       （/rest/v1/events への per-IP レート制限ルール）等のインフラ側で対処する。
