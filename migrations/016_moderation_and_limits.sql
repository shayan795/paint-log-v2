-- =====================================================================
-- 016_moderation_and_limits.sql
--   最大規模監査(150件収集・56件検証)で確認された、モデレーションと容量の穴を塞ぐ。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（015 の後）。冪等。
-- =====================================================================

-- ---------------------------------------------------------------------
-- (1) 通報記録が「投稿の削除」で道連れに消える
--
--   reports.recipe_id は ON DELETE CASCADE だったため、
--   ・運営が通報対応で投稿を削除した瞬間に、通報記録・対応履歴が消える
--   ・荒らし本人が自分の投稿を消せば証拠隠滅できる
--   ・BAN/解除ボタンは通報カード内にしか無いため、通報が消えると停止も解除もできなくなる
--   という三重の問題が起きていた。通報は投稿と独立して残す。
-- ---------------------------------------------------------------------
alter table public.reports add column if not exists recipe_owner_id uuid;   -- 通報時点の投稿者
alter table public.reports add column if not exists recipe_title   text;    -- 通報時点の題名
alter table public.reports add column if not exists recipe_cover    text;   -- 通報時点のカバー画像

-- 既存行に、まだ残っている投稿の情報を写しておく
update public.reports rp
   set recipe_owner_id = r.owner_id,
       recipe_title    = r.title,
       recipe_cover    = r.cover_url
  from public.recipes r
 where r.id = rp.recipe_id and rp.recipe_owner_id is null;

alter table public.reports alter column recipe_id drop not null;
alter table public.reports drop constraint if exists reports_recipe_id_fkey;
alter table public.reports add  constraint reports_recipe_id_fkey
  foreign key (recipe_id) references public.recipes(id) on delete set null;

-- 通報が入った時点で投稿の情報を写す（後で投稿が消えても誰の何が通報されたか分かる）
create or replace function public.snapshot_report_target()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select owner_id, title, cover_url
    into NEW.recipe_owner_id, NEW.recipe_title, NEW.recipe_cover
    from public.recipes where id = NEW.recipe_id;
  return NEW;
end; $$;
drop trigger if exists trg_snapshot_report_target on public.reports;
create trigger trg_snapshot_report_target before insert on public.reports
  for each row execute function public.snapshot_report_target();

-- 通報集計は「通報時点の投稿者」を基準にする（投稿が消えても集計から消えないように）
create or replace function public.report_summary(limit_n int default 30)
returns table(
  owner_id uuid, user_id text, display_name text,
  report_count bigint, recipe_count bigint, last_report timestamptz,
  distinct_reporters bigint, banned boolean
)
language sql stable security definer set search_path = public as $$
  select coalesce(rp.recipe_owner_id, r.owner_id) as owner_id,
         p.user_id, p.display_name,
         count(*)                            as report_count,
         count(distinct rp.recipe_id)        as recipe_count,
         max(rp.created_at)                  as last_report,
         count(distinct rp.reporter_id)      as distinct_reporters,
         (p.banned_at is not null)           as banned
  from public.reports rp
  left join public.recipes  r on r.id = rp.recipe_id
  join      public.profiles p on p.id = coalesce(rp.recipe_owner_id, r.owner_id)
  where public.is_admin()
  group by coalesce(rp.recipe_owner_id, r.owner_id), p.user_id, p.display_name, p.banned_at
  order by count(distinct rp.reporter_id) desc, count(*) desc, max(rp.created_at) desc
  limit greatest(1, least(coalesce(limit_n,30), 100));
$$;
revoke all on function public.report_summary(int) from public, anon;
grant execute on function public.report_summary(int) to authenticated;

-- ---------------------------------------------------------------------
-- (2) BAN（利用停止）が新規作成しか止めていなかった
--
--   停止された利用者でも、既存投稿の書き換え・非公開→公開への切替・写真の差し替えが
--   自由にできたため、荒らしの手が実際には止まらなかった。
--   ★閲覧・削除・退会は妨げない（自分のデータを引き上げる権利は残す）。
-- ---------------------------------------------------------------------
create or replace function public.block_banned_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and public.is_banned(auth.uid()) then
    raise exception 'このアカウントは現在ご利用を停止しています。内容の変更はできません。';
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_block_banned_update_recipes on public.recipes;
create trigger trg_block_banned_update_recipes before update on public.recipes
  for each row execute function public.block_banned_update();

drop trigger if exists trg_block_banned_update_drafts on public.drafts;
create trigger trg_block_banned_update_drafts before update on public.drafts
  for each row execute function public.block_banned_update();

drop trigger if exists trg_block_banned_update_comments on public.comments;
create trigger trg_block_banned_update_comments before update on public.comments
  for each row execute function public.block_banned_update();

-- プロフィール（表示名・自己紹介・アイコン）も停止中は変更させない（宣伝文の書き換え対策）
create or replace function public.block_banned_profile_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- 停止フラグ自体の更新(set_user_ban)は通す
  if coalesce(current_setting('app.allow_ban', true), '') = '1' then return NEW; end if;
  if auth.uid() is not null and auth.uid() = NEW.id and public.is_banned(auth.uid())
     and (NEW.display_name is distinct from OLD.display_name
       or NEW.bio          is distinct from OLD.bio
       or NEW.link         is distinct from OLD.link
       or NEW.avatar_url   is distinct from OLD.avatar_url
       or NEW.header_url   is distinct from OLD.header_url) then
    raise exception 'このアカウントは現在ご利用を停止しています。プロフィールの変更はできません。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_block_banned_profile on public.profiles;
create trigger trg_block_banned_profile before update on public.profiles
  for each row execute function public.block_banned_profile_update();

-- ---------------------------------------------------------------------
-- (3) BANが「退会→同じメールで再登録」でリセットされる
--   停止したメールアドレスを記録し、再登録時に停止状態を引き継ぐ。
-- ---------------------------------------------------------------------
create table if not exists public.banned_emails (
  email      text primary key,
  reason     text,
  banned_at  timestamptz not null default now()
);
alter table public.banned_emails enable row level security;
revoke all on public.banned_emails from anon, authenticated;

-- 停止時にメールを記録（set_user_ban から呼ばれる）
create or replace function public.remember_banned_email(target uuid, reason text)
returns void language plpgsql security definer set search_path to 'public','auth' as $$
declare em text;
begin
  select email into em from auth.users where id = target;
  if em is null then return; end if;
  insert into public.banned_emails(email, reason) values (lower(em), reason)
    on conflict (email) do update set reason = excluded.reason, banned_at = now();
end; $$;
revoke all on function public.remember_banned_email(uuid, text) from public, anon, authenticated;

-- 新規登録時、そのメールが停止リストにあれば停止状態で作成する
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare bl record;
begin
  insert into public.profiles (id, has_password)
  values (new.id, (new.encrypted_password is not null and new.encrypted_password <> ''))
  on conflict (id) do nothing;

  select * into bl from public.banned_emails where email = lower(new.email);
  if found then
    update public.profiles
       set banned_at = now(),
           banned_reason = coalesce(bl.reason, '利用規約違反によりご利用を停止しています。')
     where id = new.id;
  end if;
  return new;
end; $$;

-- ---------------------------------------------------------------------
-- (4) Storageバケットに上限が無い
--   1ファイルのサイズ上限とMIME制限が未設定で、投稿レート制限を
--   アップロードだけで迂回して容量を食い潰せた。
-- ---------------------------------------------------------------------
update storage.buckets
   set file_size_limit = 10485760,                                        -- 1ファイル10MBまで
       allowed_mime_types = array['image/jpeg','image/png','image/webp']  -- 画像のみ
 where id in ('recipes','profile');

-- ---------------------------------------------------------------------
-- (5) 削除したコメントの本文が、相手の通知に残り続ける
--   「消したつもりが消えていない」状態だったので、削除時に通知本文も伏せる。
-- ---------------------------------------------------------------------
create or replace function public.scrub_comment_notifications()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.notifications
     set body = '（削除されたコメント）'
   where type in ('comment','reply')
     and link like '%' || OLD.recipe_id::text || '%'
     and body like '%' || left(OLD.body, 20) || '%';
  return OLD;
end; $$;
drop trigger if exists trg_scrub_comment_notifications on public.comments;
create trigger trg_scrub_comment_notifications after delete on public.comments
  for each row execute function public.scrub_comment_notifications();
