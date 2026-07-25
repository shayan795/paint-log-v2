-- =====================================================================
-- 009_delete_user_storage_fix.sql
--   ★005 の delete_user の不具合修正（重要）
--
--   005 で「退会時に本人の画像も消す」処理を入れたが、Supabase には
--   storage.objects への直接DELETEを禁止するトリガ storage.protect_delete() があり、
--   そのままでは退会そのものが例外で失敗する（＝退会できなくなる）。
--
--   対策:
--     ・削除前に storage.allow_delete_query をトランザクション内だけ true にする
--     ・画像削除が失敗しても、アカウント削除は必ず実行されるよう例外を握る
--       （「退会できない」ことの方が「画像が残る」ことより重大なため）
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（008 の後）。冪等。
-- =====================================================================

create or replace function public.delete_user()
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
begin
  begin
    perform set_config('storage.allow_delete_query', 'true', true);   -- このトランザクション内だけ許可
    delete from storage.objects
     where bucket_id in ('recipes','profile')
       and (storage.foldername(name))[1] = auth.uid()::text;
  exception when others then
    null;   -- 画像削除に失敗しても退会は続行する
  end;
  delete from auth.users where id = auth.uid();
end; $$;
grant execute on function public.delete_user() to authenticated;

-- ---------------------------------------------------------------------
-- 退会済みユーザーの孤児画像を掃除する関数（今回の一括削除にも使用）。
-- auth.users に存在しないUUIDフォルダ配下だけを対象にするため、現役ユーザーの画像は消えない。
-- 定期実行するなら purge_old_events と同様に手動 or pg_cron で。
-- ---------------------------------------------------------------------
create or replace function public.purge_orphan_storage()
returns int language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare n int;
begin
  perform set_config('storage.allow_delete_query', 'true', true);
  with del as (
    delete from storage.objects o
     where o.bucket_id in ('recipes','profile')
       and (storage.foldername(o.name))[1] ~ '^[0-9a-f-]{36}$'
       and not exists (select 1 from auth.users u where u.id::text = (storage.foldername(o.name))[1])
    returning 1
  )
  select count(*) into n from del;
  return n;
end; $$;
revoke all on function public.purge_orphan_storage() from public, anon, authenticated;
