-- =====================================================================
-- 018_report_target.sql
--   【High】コメントを通報すると、違反コメントの投稿者ではなく
--          「レシピの投稿者」が停止対象として表示されていた問題の修正。
--
--   これまで通報は recipe_id しか持たず、管理画面は常に
--   「そのレシピの持ち主」を停止候補にしていた。
--   → BがAのレシピに違反コメントを書き、Cがそれを通報すると、
--      運営が「投稿者を停止」を押したとき無実のAが停止され、Bは残る。
--
--   対策: 通報に「何に対する通報か」と「誰に対する通報か」をサーバー側で確定して保存する。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（017 の後）。冪等。
-- =====================================================================

alter table public.reports add column if not exists target_type      text;    -- 'recipe' / 'comment'
alter table public.reports add column if not exists target_user_id   uuid;    -- 停止候補（違反者本人）
alter table public.reports add column if not exists target_comment_id bigint; -- コメント通報のとき
alter table public.reports add column if not exists target_body      text;    -- 通報時点の本文（消されても残る証拠）

-- 通報の作成時に、対象種別と対象者をサーバー側で確定する。
-- クライアントから送られる値は信用せず、必ずDBの実データから引く。
create or replace function public.snapshot_report_target()
returns trigger language plpgsql security definer set search_path = public as $$
declare c record;
begin
  -- 投稿側の情報（削除後も残すためのスナップショット）
  select owner_id, title, cover_url
    into NEW.recipe_owner_id, NEW.recipe_title, NEW.recipe_cover
    from public.recipes where id = NEW.recipe_id;

  if NEW.target_comment_id is not null then
    -- コメントへの通報：対象者はコメントの投稿者
    select user_id, body, recipe_id into c
      from public.comments where id = NEW.target_comment_id;
    if not found then
      raise exception '通報対象のコメントが見つかりません';
    end if;
    if NEW.recipe_id is not null and c.recipe_id is distinct from NEW.recipe_id then
      raise exception '通報対象のコメントが投稿と一致しません';
    end if;
    NEW.target_type    := 'comment';
    NEW.target_user_id := c.user_id;
    NEW.target_body    := left(coalesce(c.body,''), 500);
  else
    -- 投稿への通報：対象者は投稿者
    NEW.target_type    := 'recipe';
    NEW.target_user_id := NEW.recipe_owner_id;
    NEW.target_body    := null;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_snapshot_report_target on public.reports;
create trigger trg_snapshot_report_target before insert on public.reports
  for each row execute function public.snapshot_report_target();

-- 既存の通報にも対象者を埋める（detail に 'comment:<id>' を書いていた旧形式を拾う）
update public.reports r
   set target_comment_id = coalesce(r.target_comment_id,
         nullif(substring(coalesce(r.detail,'') from 'comment:([0-9]+)'), '')::bigint)
 where r.target_comment_id is null and coalesce(r.detail,'') like 'comment:%';

update public.reports r
   set target_type    = coalesce(r.target_type, case when r.target_comment_id is not null then 'comment' else 'recipe' end),
       target_user_id = coalesce(r.target_user_id,
                          (select c.user_id from public.comments c where c.id = r.target_comment_id),
                          r.recipe_owner_id)
 where r.target_user_id is null or r.target_type is null;

-- 通報の集計も「違反者本人」単位にする（無実の投稿者が候補に出ないように）
create or replace function public.report_summary(limit_n int default 30)
returns table(
  owner_id uuid, user_id text, display_name text,
  report_count bigint, recipe_count bigint, last_report timestamptz,
  distinct_reporters bigint, banned boolean
)
language sql stable security definer set search_path = public as $$
  select rp.target_user_id as owner_id,
         p.user_id, p.display_name,
         count(*) as report_count,
         count(distinct rp.recipe_id) as recipe_count,
         max(rp.created_at) as last_report,
         count(distinct rp.reporter_id) as distinct_reporters,
         (p.banned_at is not null) as banned
  from public.reports rp
  join public.profiles p on p.id = rp.target_user_id
  where public.is_admin() and rp.target_user_id is not null
  group by rp.target_user_id, p.user_id, p.display_name, p.banned_at
  order by count(distinct rp.reporter_id) desc, count(*) desc, max(rp.created_at) desc
  limit greatest(1, least(coalesce(limit_n,30), 100));
$$;
revoke all on function public.report_summary(int) from public, anon;
grant execute on function public.report_summary(int) to authenticated;

-- 管理者がコメントを削除できるようにする（違反コメントへの対処導線）
-- ※comments_delete は既に「本人 or 管理者」だが、ここで明示的に再定義して意図を残す
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments
  for delete using (user_id = auth.uid() or public.is_admin());
