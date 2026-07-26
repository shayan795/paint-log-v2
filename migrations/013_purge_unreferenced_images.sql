-- =====================================================================
-- 013_purge_unreferenced_images.sql
--   「投稿を編集して写真を差し替えると、古い写真がStorageに残り続ける」問題の解消。
--
--   現状（実測）: recipes バケット75件のうち 44件・23.2MB が、どの投稿・下書きからも
--   参照されていない古い画像だった（全体の約7割）。URLを知っていれば取得でき、
--   このペースだと約60ユーザーで無料枠1GBが埋まって投稿できなくなる。
--
--   方針: 「今どこかから参照されている画像だけを残す」。投稿・下書きが変化したら、
--   その持ち主の未参照画像を自動で削除する（クライアントの実装に依存しないようDB側で行う）。
--
--   ★安全装置: アップロード直後（1時間以内）のファイルは削除しない。
--     編集中で「アップロード済みだがまだ保存していない」画像を巻き込まないため。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（012 の後）。冪等。
-- =====================================================================

-- 公開URL → Storage内パス（バケット指定版。011のrecipes専用版はそのまま残す）
create or replace function public.storage_path_of(u text, bucket text)
returns text language sql immutable as $$
  select nullif(substring(coalesce(u,'') from '/object/public/' || bucket || '/(.*)$'), '');
$$;

-- 指定ユーザーの「どこからも参照されていない画像」を削除する
create or replace function public.purge_unreferenced_images(p_owner uuid)
returns int language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare n int := 0;
begin
  if p_owner is null then return 0; end if;
  perform set_config('storage.allow_delete_query', 'true', true);

  with used as (
    -- 投稿（カバー・完成写真・色グループ写真）
    select public.storage_path_of(cover_url,'recipes') as p from public.recipes where owner_id = p_owner
    union all
    select public.storage_path_of(x,'recipes') from public.recipes r,
      jsonb_array_elements_text(case when jsonb_typeof(r.grid->'photos')='array' then r.grid->'photos' else '[]'::jsonb end) x
      where r.owner_id = p_owner
    union all
    select public.storage_path_of(e->>'photo','recipes') from public.recipes r,
      jsonb_array_elements(case when jsonb_typeof(r.grid->'rows')='array' then r.grid->'rows' else '[]'::jsonb end) e
      where r.owner_id = p_owner
    -- 下書き（同じバケットに入る）
    union all
    select public.storage_path_of(cover_url,'recipes') from public.drafts where owner_id = p_owner
    union all
    select public.storage_path_of(x,'recipes') from public.drafts d,
      jsonb_array_elements_text(case when jsonb_typeof(d.grid->'photos')='array' then d.grid->'photos' else '[]'::jsonb end) x
      where d.owner_id = p_owner
    union all
    select public.storage_path_of(e->>'photo','recipes') from public.drafts d,
      jsonb_array_elements(case when jsonb_typeof(d.grid->'rows')='array' then d.grid->'rows' else '[]'::jsonb end) e
      where d.owner_id = p_owner
  ), del as (
    delete from storage.objects o
     where o.bucket_id = 'recipes'
       and (storage.foldername(o.name))[1] = p_owner::text
       and o.created_at < now() - interval '1 hour'          -- 保存前の画像を巻き込まない
       and o.name not in (select p from used where p is not null)
    returning 1
  )
  select count(*) into n from del;
  return n;
end; $$;
revoke all on function public.purge_unreferenced_images(uuid) from public, anon, authenticated;

-- プロフィール画像（アイコン・ヘッダー）の古い版も同様に掃除する
create or replace function public.purge_unreferenced_profile_images(p_owner uuid)
returns int language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare n int := 0;
begin
  if p_owner is null then return 0; end if;
  perform set_config('storage.allow_delete_query', 'true', true);
  with used as (
    select public.storage_path_of(avatar_url,'profile') as p from public.profiles where id = p_owner
    union all
    select public.storage_path_of(header_url,'profile') from public.profiles where id = p_owner
  ), del as (
    delete from storage.objects o
     where o.bucket_id = 'profile'
       and (storage.foldername(o.name))[1] = p_owner::text
       and o.created_at < now() - interval '1 hour'
       and o.name not in (select p from used where p is not null)
    returning 1
  )
  select count(*) into n from del;
  return n;
end; $$;
revoke all on function public.purge_unreferenced_profile_images(uuid) from public, anon, authenticated;

-- 投稿・下書きが変化したら、その持ち主の未参照画像を自動で掃除する
create or replace function public.trg_purge_images()
returns trigger language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare o uuid;
begin
  o := coalesce(NEW.owner_id, OLD.owner_id);
  begin
    perform public.purge_unreferenced_images(o);
  exception when others then null;   -- 掃除の失敗で保存を止めない
  end;
  return null;
end; $$;

drop trigger if exists trg_purge_images_recipes on public.recipes;
create trigger trg_purge_images_recipes after insert or update or delete on public.recipes
  for each row execute function public.trg_purge_images();

drop trigger if exists trg_purge_images_drafts on public.drafts;
create trigger trg_purge_images_drafts after insert or update or delete on public.drafts
  for each row execute function public.trg_purge_images();

-- プロフィール更新時
create or replace function public.trg_purge_profile_images()
returns trigger language plpgsql security definer set search_path to 'public','auth','storage' as $$
begin
  begin
    perform public.purge_unreferenced_profile_images(NEW.id);
  exception when others then null;
  end;
  return null;
end; $$;
drop trigger if exists trg_purge_images_profiles on public.profiles;
create trigger trg_purge_images_profiles after update on public.profiles
  for each row execute function public.trg_purge_profile_images();
