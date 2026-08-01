-- ============================================================================
-- 022: 外部監査(Codex 2026-08-01)で確認できた2件を塞ぐ
-- ※ Supabase の SQL Editor で実行してください（021の後）。冪等。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) 他人の has_password / banned_at が、ログインしていれば誰でも読めた
-- ----------------------------------------------------------------------------
-- ★何が漏れていたか（実測で確認）
--   profiles の SELECT ポリシーは `true`（誰でも全行読める）。
--   守りは「列ごとの読み取り権限」だけなのに、この2列は authenticated に許可されていた。
--     has_password … その人がパスワードを持つか＝Googleログイン専用かが分かる
--     banned_at    … 誰が利用停止中かが一覧できる
--   どちらも他人に見せる必要がまったく無い。停止中の人が誰かを外から数えられるのは、
--   本人の不利益になりうる（晒し・詮索の材料になる）。
--
-- ★なぜ「ポリシーを厳しくする」のではなく列権限で塞ぐか
--   プロフィールは他人の分も表示する必要がある（投稿者名・アイコン）。
--   行の制限を掛けると通常表示が壊れる。列を閉じるのが影響最小。
revoke select (has_password) on public.profiles from authenticated;
revoke select (banned_at)    on public.profiles from authenticated;
-- anon には元から付いていない（実測確認済み）。念のため明示。
revoke select (has_password, banned_at) on public.profiles from anon;

-- 自分の分は public.my_profile()（021）から読めるので、設定画面は影響を受けない。

-- 管理者の通報画面だけは他人の停止状態を見る必要があるため、専用の入口を用意する。
-- security definer だが、先頭で is_admin() を確認するので管理者以外は何も得られない。
create or replace function public.admin_user_states(ids uuid[])
returns table (id uuid, user_id text, display_name text, banned_at timestamptz)
language plpgsql security definer set search_path to 'public','auth' as $$
begin
  if not public.is_admin() then
    raise exception '権限がありません';
  end if;
  return query
    select p.id, p.user_id, p.display_name, p.banned_at
      from public.profiles p
     where p.id = any(coalesce(ids, '{}'::uuid[]))
     limit 500;                       -- 一度に取り過ぎない安全弁
end $$;
revoke all on function public.admin_user_states(uuid[]) from public, anon;
grant execute on function public.admin_user_states(uuid[]) to authenticated;

comment on function public.admin_user_states(uuid[]) is
  '通報画面用。対象者の表示名と停止状態を管理者だけが取得する。banned_at は列権限を外したため、この関数が唯一の入口。';

-- ----------------------------------------------------------------------------
-- (2) 容量・BANの制限が INSERT にしか掛かっておらず、UPDATE で迂回できた
-- ----------------------------------------------------------------------------
-- ★何が抜けていたか（実測で確認）
--   019で入れた guard は `before insert` だけ。
--   一方 storage.objects の書き込みポリシーは recipes_img_write / profile_write とも
--   `for all`（＝UPDATE も許可）。
--   Storage APIの upsert は既存パスに対して UPDATE になるため、
--   同じパスへ大きなファイルを上書きし続ければ、
--   1人200MB・500件の上限も、利用停止(BAN)中の禁止も素通りできた。
--
-- → INSERT と UPDATE の両方に掛ける。
--   UPDATE のときは「増えた分」だけを見る（同じ大きさへの入れ替えは通す）。
create or replace function public.check_storage_upload()
returns trigger language plpgsql security definer
set search_path to 'public','storage' as $$
declare
  reason   text;
  old_size bigint := 0;
  new_size bigint := 0;
begin
  if TG_OP = 'UPDATE' then
    -- 中身の入れ替えだけで、置き場所も大きさも増えないなら素通しする
    -- （画像の差し替えを禁止したいわけではない。増やせないようにしたい）
    begin old_size := coalesce((OLD.metadata->>'size')::bigint, 0); exception when others then old_size := 0; end;
    begin new_size := coalesce((NEW.metadata->>'size')::bigint, 0); exception when others then new_size := 0; end;
    if NEW.bucket_id is not distinct from OLD.bucket_id
       and NEW.name is not distinct from OLD.name
       and new_size <= old_size then
      return NEW;
    end if;
  end if;

  reason := public.storage_upload_denied_reason(NEW.bucket_id, NEW.name, NEW.metadata);
  if reason is not null then raise exception '%', reason; end if;
  return NEW;
end $$;

-- トリガを張り直す（INSERT だけの旧定義を置き換える）。
-- storage.objects は supabase_storage_admin の持ち物で権限が環境によって違うため、
-- 失敗しても migration 全体は止めず、NOTICE で知らせる（019と同じ方針）。
do $$
begin
  begin
    drop trigger if exists trg_check_storage_upload on storage.objects;
    execute 'create trigger trg_check_storage_upload'
         || ' before insert or update on storage.objects'
         || ' for each row execute function public.check_storage_upload()';
    raise notice '容量guard: INSERT と UPDATE の両方に掛けました';
  exception when others then
    raise notice '★容量guardのトリガを張り直せませんでした: %', sqlerrm;
  end;
end $$;
