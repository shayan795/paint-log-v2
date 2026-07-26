-- =====================================================================
-- 015_test_found_fixes.sql
--   ★自動テスト(603本)が発見した実際の不具合をまとめて修正する。
--   Critical 3件を含む。特に (1) は本番で稼働中の重大な穴。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（014 の後）。冪等。
-- =====================================================================

-- ---------------------------------------------------------------------
-- (1)【Critical】未ログインの誰でも、他人の投稿・下書き・画像を削除できた
--
--   011で書いた権限チェック
--       if r.owner_id <> auth.uid() and not public.is_admin() then raise ...
--   は、未ログイン(auth.uid()がNULL)のとき
--       「値 <> NULL」→ NULL → 条件が偽とみなされる
--   ため素通りし、そのまま削除処理に進んでいた（フェイルオープン）。
--   さらに関数のEXECUTE権限がPUBLICに残っていたため、匿名でも呼び出せた。
--
--   対策: ①ログイン必須を明示 ②NULL安全な比較(is distinct from) ③匿名から実行権限を剥奪
-- ---------------------------------------------------------------------
create or replace function public.delete_recipe_with_images(rid uuid)
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare r record; paths text[];
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;   -- ★追加
  select owner_id, cover_url, grid into r from public.recipes where id = rid;
  if not found then raise exception '投稿が見つかりません'; end if;
  if r.owner_id is distinct from auth.uid() and not public.is_admin() then   -- ★NULL安全に
    raise exception 'この投稿を削除する権限がありません';
  end if;

  select array_remove(array_agg(distinct p), null) into paths from (
    select public.storage_path_from_url(r.cover_url) as p
    union all
    select public.storage_path_from_url(x) from jsonb_array_elements_text(
      case when jsonb_typeof(r.grid->'photos') = 'array' then r.grid->'photos' else '[]'::jsonb end) as x
    union all
    select public.storage_path_from_url(row_elem->>'photo')
      from jsonb_array_elements(
        case when jsonb_typeof(r.grid->'rows') = 'array' then r.grid->'rows' else '[]'::jsonb end) as row_elem
  ) s;

  if paths is not null and array_length(paths,1) > 0 then
    perform set_config('storage.allow_delete_query', 'true', true);
    delete from storage.objects where bucket_id = 'recipes' and name = any(paths);
  end if;

  delete from public.recipes where id = rid;
end; $$;
revoke all on function public.delete_recipe_with_images(uuid) from public, anon;
grant execute on function public.delete_recipe_with_images(uuid) to authenticated;

create or replace function public.delete_draft_with_images(did uuid)
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare d record; paths text[];
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;   -- ★追加
  select owner_id, cover_url, grid into d from public.drafts where id = did;
  if not found then return; end if;
  if d.owner_id is distinct from auth.uid() then                              -- ★NULL安全に
    raise exception 'この下書きを削除する権限がありません';
  end if;

  select array_remove(array_agg(distinct p), null) into paths from (
    select public.storage_path_from_url(d.cover_url) as p
    union all
    select public.storage_path_from_url(x) from jsonb_array_elements_text(
      case when jsonb_typeof(d.grid->'photos') = 'array' then d.grid->'photos' else '[]'::jsonb end) as x
    union all
    select public.storage_path_from_url(row_elem->>'photo')
      from jsonb_array_elements(
        case when jsonb_typeof(d.grid->'rows') = 'array' then d.grid->'rows' else '[]'::jsonb end) as row_elem
  ) s;

  if paths is not null and array_length(paths,1) > 0 then
    select array_remove(array_agg(p), null) into paths from unnest(paths) as p
     where not exists (
       select 1 from public.recipes r
        where public.storage_path_from_url(r.cover_url) = p
           or r.grid::text like '%' || p || '%'
     );
  end if;

  if paths is not null and array_length(paths,1) > 0 then
    perform set_config('storage.allow_delete_query', 'true', true);
    delete from storage.objects where bucket_id = 'recipes' and name = any(paths);
  end if;

  delete from public.drafts where id = did;
end; $$;
revoke all on function public.delete_draft_with_images(uuid) from public, anon;
grant execute on function public.delete_draft_with_images(uuid) to authenticated;

-- 退会・通報集計も匿名からは呼べないようにする（実害は無いが原則どおり閉じる）
create or replace function public.delete_user()
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  begin
    perform set_config('storage.allow_delete_query', 'true', true);
    delete from storage.objects
     where bucket_id in ('recipes','profile')
       and (storage.foldername(name))[1] = auth.uid()::text;
  exception when others then null;
  end;
  delete from auth.users where id = auth.uid();
end; $$;
revoke all on function public.delete_user() from public, anon;
grant execute on function public.delete_user() to authenticated;
revoke all on function public.report_summary(int) from public, anon;
grant execute on function public.report_summary(int) to authenticated;

-- ---------------------------------------------------------------------
-- (2)【Critical/High】停止(BAN)された人が、自分で停止を解除できた
--
--   profiles は「自分の行なら更新してよい」というRLSのみで、列ごとの保護が無かった。
--   そのため停止された本人が banned_at を消す(=自力解除)ことも、
--   運営が記録した停止理由を書き換えることもできた。
--   is_admin だけは既にトリガで守られていたのに、後から足した列が漏れていた。
--
--   対策: is_admin と同じ方式で banned_at / banned_reason / has_password も巻き戻す。
--        運営の set_user_ban だけは、トランザクション内フラグで通す。
-- ---------------------------------------------------------------------
create or replace function public.guard_profile_admin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    if auth.uid() is not null then
      NEW.is_admin := false;
      NEW.banned_at := null;
      NEW.banned_reason := null;
      NEW.has_password := false;
    end if;
    return NEW;
  end if;

  if auth.uid() is not null then
    -- 管理者フラグは誰であっても自分では変えられない
    if NEW.is_admin is distinct from OLD.is_admin then NEW.is_admin := OLD.is_admin; end if;

    -- 停止状態は set_user_ban（運営の操作）以外からは変えられない
    if coalesce(current_setting('app.allow_ban', true), '') <> '1' then
      if NEW.banned_at     is distinct from OLD.banned_at     then NEW.banned_at := OLD.banned_at; end if;
      if NEW.banned_reason is distinct from OLD.banned_reason then NEW.banned_reason := OLD.banned_reason; end if;
    end if;

    -- 認証方式はサーバー(auth.users)側で確定する。自己申告での書き換えは無効。
    if NEW.has_password is distinct from OLD.has_password then NEW.has_password := OLD.has_password; end if;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_guard_profile_admin on public.profiles;
create trigger trg_guard_profile_admin before insert or update on public.profiles
  for each row execute function public.guard_profile_admin();

-- 運営の停止／解除だけは通す（フラグを立ててから更新する）
create or replace function public.set_user_ban(target uuid, ban boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '権限がありません'; end if;
  if target = auth.uid() then raise exception '自分自身は停止できません'; end if;
  if (select is_admin from public.profiles where id = target) then
    raise exception '管理者は停止できません';
  end if;

  perform set_config('app.allow_ban', '1', true);          -- ★このトランザクション内だけ許可
  update public.profiles
     set banned_at = case when ban then now() else null end,
         banned_reason = case when ban then reason else null end
   where id = target;
  perform set_config('app.allow_ban', '', true);           -- ★すぐ戻す（他の更新に波及させない）

  if ban then
    insert into public.notifications(user_id, type, title, body, link)
    values (target, 'system', 'アカウントのご利用停止',
            coalesce(nullif(btrim(reason),''), '利用規約に違反する行為が確認されたため、投稿機能のご利用を停止しました。'),
            'index.html#feedback');
  else
    insert into public.notifications(user_id, type, title, body, link)
    values (target, 'system', 'ご利用停止を解除しました',
            '投稿機能のご利用を再開いただけます。', 'index.html');
  end if;
end; $$;
revoke all on function public.set_user_ban(uuid, boolean, text) from public, anon;
grant execute on function public.set_user_ban(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- (3)【Low】閲覧数の許可フラグが立ちっぱなしで、改ざん防止が効かなくなる場合があった
-- ---------------------------------------------------------------------
create or replace function public.increment_view(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m timestamptz := date_trunc('minute', now()); c int;
begin
  insert into public.view_throttle(recipe_id, minute, cnt) values (rid, m, 1)
    on conflict (recipe_id, minute) do update set cnt = public.view_throttle.cnt + 1
    returning cnt into c;
  if c > 60 then return; end if;
  perform set_config('app.allow_view', '1', true);
  update public.recipes set view_count = view_count + 1 where id = rid and is_public = true;
  perform set_config('app.allow_view', '', true);   -- ★使い終わったら必ず消す
end; $$;
grant execute on function public.increment_view(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- (4)【Medium】見えないはずの非公開投稿のコメントに「いいね」ができた
--   読めない相手に書ける状態だったため、連番IDの総当たりで
--   非公開コメントの存在を探ることもできた。
-- ---------------------------------------------------------------------
drop policy if exists comment_likes_insert on public.comment_likes;
create policy comment_likes_insert on public.comment_likes
  for insert with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.comments c
      join public.recipes r on r.id = c.recipe_id
      where c.id = comment_id and (r.is_public or r.owner_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------
-- (5)【Medium】他人のフォルダ名を指定して画像を置けた（書き込みポリシーがフォルダを見ていなかった）
-- ---------------------------------------------------------------------
drop policy if exists recipes_img_write on storage.objects;
create policy recipes_img_write on storage.objects
  for all using (
    bucket_id = 'recipes' and owner = auth.uid()
    and (storage.foldername(name))[1] = auth.uid()::text
  ) with check (
    bucket_id = 'recipes' and owner = auth.uid()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists profile_write on storage.objects;
create policy profile_write on storage.objects
  for all using (
    bucket_id = 'profile' and owner = auth.uid()
    and (storage.foldername(name))[1] = auth.uid()::text
  ) with check (
    bucket_id = 'profile' and owner = auth.uid()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------
-- (6)【Medium】壊れたデータで「投稿の保存そのもの」が失敗していた
--   ・procs の要素がオブジェクトでない（数値など）場合
--   ・塗料番号 c.i が int の範囲を超える巨大な数値の場合
--   どちらも例外になり、利用者が投稿できなくなる。安全に読み飛ばすようにする。
-- ---------------------------------------------------------------------
create or replace function public.sync_recipe_paints(p_recipe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g jsonb; proc_map jsonb := '{}'::jsonb; p jsonb; row_elem jsonb;
  cell_key text; cell_val jsonb; v_proc text; v_paint_id text; v_free text;
begin
  select grid into g from public.recipes where id = p_recipe_id;
  delete from public.recipe_paints where recipe_id = p_recipe_id;
  if g is null then return; end if;

  if jsonb_typeof(g->'procs') = 'array' then
    for p in select jsonb_array_elements(g->'procs') loop
      if jsonb_typeof(p) = 'object' and p->>'id' is not null then     -- ★型を確認してから使う
        proc_map := proc_map || jsonb_build_object(p->>'id', p->>'name');
      end if;
    end loop;
  end if;

  if jsonb_typeof(g->'rows') = 'array' then
    for row_elem in select jsonb_array_elements(g->'rows') loop
      if jsonb_typeof(row_elem) = 'object' and jsonb_typeof(row_elem->'cells') = 'object' then
        for cell_key, cell_val in select key, value from jsonb_each(row_elem->'cells') loop
          v_proc := proc_map->>cell_key; v_paint_id := null; v_free := null;
          if jsonb_typeof(cell_val) = 'object' then
            if cell_val ? 'i' and (cell_val->>'i') ~ '^[0-9]{1,9}$' then   -- ★桁あふれを防ぐ
              select id into v_paint_id from public.paints where sort_order = (cell_val->>'i')::int;
            elsif cell_val ? 'c' then
              v_free := nullif(btrim(cell_val->>'c'), '');
            end if;
          end if;
          if v_paint_id is not null or v_free is not null then
            insert into public.recipe_paints(recipe_id, paint_id, free_name, proc_name)
            values (p_recipe_id, v_paint_id, v_free, v_proc);
          end if;
        end loop;
      end if;
    end loop;
  end if;
end; $$;

-- ---------------------------------------------------------------------
-- (7)【Low】通知の重複防止表(clip_notified)に孤児行が残り続ける
-- ---------------------------------------------------------------------
delete from public.clip_notified c
 where not exists (select 1 from public.profiles p where p.id = c.clipper_id)
    or not exists (select 1 from public.recipes r where r.id = c.recipe_id);

alter table public.clip_notified drop constraint if exists clip_notified_clipper_fk;
alter table public.clip_notified add  constraint clip_notified_clipper_fk
  foreign key (clipper_id) references public.profiles(id) on delete cascade;
alter table public.clip_notified drop constraint if exists clip_notified_recipe_fk;
alter table public.clip_notified add  constraint clip_notified_recipe_fk
  foreign key (recipe_id) references public.recipes(id) on delete cascade;
