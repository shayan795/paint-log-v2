-- =====================================================================
-- 017_codex_fixes.sql
--   外部レビュー(Codex)が発見した不具合の修正。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（016 の後）。冪等。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 【High #2】自分の投稿を経由して他人の画像を削除できた
--   削除RPCは「レシピの持ち主か」しか見ておらず、レシピ本文(grid/cover_url)に
--   書かれた画像パスが誰のものかを検証していなかった。
--   → 他人の公開画像URLを自分のレシピに書いてから自分のレシピを消すと、
--      他人の画像のStorage登録が消える（＝以後その画像が管理・削除できなくなる）。
--   対策: 削除対象を「自分のフォルダ配下」かつ「他の投稿・下書きから参照されていない」ものに限定する。
-- ---------------------------------------------------------------------
create or replace function public.delete_recipe_with_images(rid uuid)
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare r record; paths text[]; me uuid := auth.uid();
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select owner_id, cover_url, grid into r from public.recipes where id = rid;
  if not found then raise exception '投稿が見つかりません'; end if;
  if r.owner_id is distinct from me and not public.is_admin() then
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

  -- ★ここが修正点: 投稿の持ち主のフォルダ配下だけに限定する（他人の画像を巻き込まない）
  if paths is not null and array_length(paths,1) > 0 then
    select array_remove(array_agg(p), null) into paths from unnest(paths) as p
     where split_part(p, '/', 1) = r.owner_id::text;
  end if;

  -- ★他の投稿・下書きがまだ使っている画像は消さない
  if paths is not null and array_length(paths,1) > 0 then
    select array_remove(array_agg(p), null) into paths from unnest(paths) as p
     where not exists (
       select 1 from public.recipes o
        where o.id <> rid
          and (public.storage_path_from_url(o.cover_url) = p or o.grid::text like '%'||p||'%')
     )
     and not exists (
       select 1 from public.drafts d
        where public.storage_path_from_url(d.cover_url) = p or d.grid::text like '%'||p||'%'
     );
  end if;

  if paths is not null and array_length(paths,1) > 0 then
    perform set_config('storage.allow_delete_query', 'true', true);
    delete from storage.objects where bucket_id = 'recipes' and name = any(paths);
  end if;

  delete from public.recipes where id = rid;
end; $$;
revoke all on function public.delete_recipe_with_images(uuid) from public, anon;
grant execute on function public.delete_recipe_with_images(uuid) to authenticated;

-- 下書き削除も同様に、自分のフォルダ配下に限定する
create or replace function public.delete_draft_with_images(did uuid)
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare d record; paths text[]; me uuid := auth.uid();
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select owner_id, cover_url, grid into d from public.drafts where id = did;
  if not found then return; end if;
  if d.owner_id is distinct from me then
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
     where split_part(p, '/', 1) = d.owner_id::text
       and not exists (
         select 1 from public.recipes r
          where public.storage_path_from_url(r.cover_url) = p or r.grid::text like '%'||p||'%'
       )
       and not exists (
         select 1 from public.drafts o
          where o.id <> did
            and (public.storage_path_from_url(o.cover_url) = p or o.grid::text like '%'||p||'%')
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

-- ---------------------------------------------------------------------
-- 【Low #22】is_banned が匿名から実行でき、任意の利用者の停止状態を照会できた
-- ---------------------------------------------------------------------
revoke all on function public.is_banned(uuid) from public, anon;
grant execute on function public.is_banned(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 【High #6】BAN時に再登録防止の記録が呼ばれていない／停止中でも x_account を変更できた
-- ---------------------------------------------------------------------
create or replace function public.set_user_ban(target uuid, ban boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare em text;
begin
  if not public.is_admin() then raise exception '権限がありません'; end if;
  if target = auth.uid() then raise exception '自分自身は停止できません'; end if;
  if (select is_admin from public.profiles where id = target) then
    raise exception '管理者は停止できません';
  end if;

  perform set_config('app.allow_ban', '1', true);
  update public.profiles
     set banned_at = case when ban then now() else null end,
         banned_reason = case when ban then reason else null end
   where id = target;
  perform set_config('app.allow_ban', '', true);

  -- ★停止と同じトランザクションで、再登録防止用にメールを記録する（016で定義済みの関数を実際に呼ぶ）
  if ban then
    begin
      perform public.remember_banned_email(target);
    exception when others then null;   -- 記録に失敗しても停止自体は成立させる
    end;
  end if;

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
-- 【Medium #16】対象の無い通報を作れて、管理者通知を空通報で埋められた
--   通報の作成時に「実在し、通報者から見える投稿」であることを必須にする。
--   ※削除後も記録を残すためのスナップショット列(016)はそのまま活きる。
-- ---------------------------------------------------------------------
create or replace function public.guard_report_target()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return NEW; end if;   -- 管理・移行用の直接操作は対象外
  if NEW.recipe_id is null then
    raise exception '通報の対象が指定されていません';
  end if;
  if not exists (
    select 1 from public.recipes r
     where r.id = NEW.recipe_id and (r.is_public or r.owner_id = auth.uid())
  ) then
    raise exception '通報できない投稿です';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_guard_report_target on public.reports;
create trigger trg_guard_report_target before insert on public.reports
  for each row execute function public.guard_report_target();

-- ---------------------------------------------------------------------
-- 【Medium #17】コメント削除時の通知伏せ字が LIKE で他の通知を巻き込んだ
--   本文の先頭20文字による部分一致をやめ、コメントIDで正確に対象を絞る。
-- ---------------------------------------------------------------------
alter table public.notifications add column if not exists source_comment_id bigint;

-- 016の scrub_comment_notifications を置き換える（LIKEでの推測をやめ、コメントIDで正確に絞る）
create or replace function public.scrub_comment_notifications()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.notifications
     set body = '（削除されたコメント）'
   where source_comment_id = OLD.id;
  return OLD;
end; $$;
drop trigger if exists trg_scrub_comment_notifications on public.comments;
create trigger trg_scrub_comment_notifications after delete on public.comments
  for each row execute function public.scrub_comment_notifications();

-- ---------------------------------------------------------------------
-- 【High #8】DB容量を外部から埋められる経路をふさぐ
-- ---------------------------------------------------------------------
-- (a) 通知は自分宛でも長さと件数を制限する
alter table public.notifications drop constraint if exists notifications_len;
alter table public.notifications add  constraint notifications_len
  check (char_length(coalesce(title,'')) <= 120 and char_length(coalesce(body,'')) <= 500) not valid;

create or replace function public.check_notify_rate()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then return NEW; end if;
  -- ★運営からの通知(停止・解除・通報対応)は必ず届ける必要があるため制限しない。
  --   これを除外しないと「通知が溜まっている相手を停止できない」という事故が起きる。
  if NEW.type = 'system' then return NEW; end if;
  select count(*) into n from public.notifications
   where user_id = NEW.user_id and created_at > now() - interval '1 hour'
     and type <> 'system';
  if n >= 100 then
    raise exception '通知の作成が多すぎます。時間をおいてお試しください。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_check_notify_rate on public.notifications;
create trigger trg_check_notify_rate before insert on public.notifications
  for each row execute function public.check_notify_rate();

-- (b) 閲覧数カウントは「実在する公開投稿」のときだけ記録する（存在しないUUIDで行を作らせない）
create or replace function public.increment_view(rid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m timestamptz := date_trunc('minute', now()); c int;
begin
  if not exists (select 1 from public.recipes where id = rid and is_public) then return; end if;
  insert into public.view_throttle(recipe_id, minute, cnt) values (rid, m, 1)
    on conflict (recipe_id, minute) do update set cnt = public.view_throttle.cnt + 1
    returning cnt into c;
  if c > 60 then return; end if;
  perform set_config('app.allow_view', '1', true);
  update public.recipes set view_count = view_count + 1 where id = rid and is_public = true;
  perform set_config('app.allow_view', '', true);
end; $$;
grant execute on function public.increment_view(uuid) to anon, authenticated;

-- (c) events の session_id 長さ制限（001の制約が未適用でも効くよう再定義）
alter table public.events drop constraint if exists events_session_len;
alter table public.events add  constraint events_session_len
  check (char_length(coalesce(session_id,'')) <= 64) not valid;

-- ---------------------------------------------------------------------
-- 【High #8関連】画像掃除トリガが「閲覧数の+1」でも毎回起動していた
--   view_count の更新のたびにStorage全走査が走るため、閲覧のたびに重い処理が発生する。
--   grid と cover_url が実際に変わったときだけ動かす。
-- ---------------------------------------------------------------------
drop trigger if exists trg_purge_images_recipes on public.recipes;
create trigger trg_purge_images_recipes
  after insert or delete or update of grid, cover_url on public.recipes
  for each row execute function public.trg_purge_images();

-- ---------------------------------------------------------------------
-- 【Medium #21】通報・お問い合わせの「最長2年」保持が実装されていなかった
-- ---------------------------------------------------------------------
create or replace function public.purge_old_events()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.events        where occurred_at < now() - interval '90 days';
  delete from public.view_throttle where minute      < now() - interval '1 day';
  -- 対応が終わっているものだけを、2年経過後に削除する（対応中は残す）
  delete from public.reports   where created_at < now() - interval '2 years' and status <> 'open';
  delete from public.inquiries where created_at < now() - interval '2 years' and status <> 'open';
end; $$;
revoke all on function public.purge_old_events() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 【High #6続き】停止中に変更できない列に x_account が漏れていた
--   「変更してよい列」を列挙する方式ではなく、「停止中は表示に関わる列を一切変えられない」方式にする。
-- ---------------------------------------------------------------------
create or replace function public.block_banned_profile_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.allow_ban', true), '') = '1' then return NEW; end if;
  if auth.uid() is not null and auth.uid() = NEW.id and public.is_banned(auth.uid())
     and (NEW.display_name is distinct from OLD.display_name
       or NEW.bio          is distinct from OLD.bio
       or NEW.link         is distinct from OLD.link
       or NEW.x_account    is distinct from OLD.x_account
       or NEW.user_id      is distinct from OLD.user_id
       or NEW.avatar_url   is distinct from OLD.avatar_url
       or NEW.header_url   is distinct from OLD.header_url) then
    raise exception 'このアカウントは現在ご利用を停止しています。プロフィールの変更はできません。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_block_banned_profile on public.profiles;
create trigger trg_block_banned_profile before update on public.profiles
  for each row execute function public.block_banned_profile_update();
