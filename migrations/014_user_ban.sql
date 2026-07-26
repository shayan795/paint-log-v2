-- =====================================================================
-- 014_user_ban.sql
--   利用者の投稿停止（BAN）機能。規約第7条で約束しているのに実装が無かった。
--
--   ★方針: 「自動BANは作らない」
--     通報が集まったら自動で停止する仕組みにすると、複数アカウントから通報を集中させる
--     嫌がらせ（通報爆撃）で無実の利用者を追い出せてしまう。
--     そのため停止は必ず「運営者が通報内容を確認して手動で実行」する。
--     通報件数は"優先的に確認すべき対象を並べ替える"ためだけに使う（自動処分はしない）。
--
--   ★できること: 新規の投稿・下書き・コメント・通報を止める（＝荒らしの手を止める）。
--   ★やらないこと: 既存投稿の削除、アカウントの削除（取り返しがつかないため別操作）。
--   ★解除はワンクリック（フラグを戻すだけ。誤操作しても即復旧できる）。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（013 の後）。冪等。
-- =====================================================================

alter table public.profiles add column if not exists banned_at     timestamptz;
alter table public.profiles add column if not exists banned_reason text;

-- 停止中かどうかの判定（RLSの再帰を避けるため security definer）
create or replace function public.is_banned(uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select banned_at is not null from public.profiles where id = uid), false);
$$;
grant execute on function public.is_banned(uuid) to authenticated;

-- 停止中の利用者による新規作成を止める（既存データの閲覧・編集・退会は妨げない）
create or replace function public.block_if_banned()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and public.is_banned(auth.uid()) then
    raise exception 'このアカウントは現在ご利用を停止しています。お問い合わせください。';
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_block_banned_recipes on public.recipes;
create trigger trg_block_banned_recipes before insert on public.recipes
  for each row execute function public.block_if_banned();

drop trigger if exists trg_block_banned_drafts on public.drafts;
create trigger trg_block_banned_drafts before insert on public.drafts
  for each row execute function public.block_if_banned();

drop trigger if exists trg_block_banned_comments on public.comments;
create trigger trg_block_banned_comments before insert on public.comments
  for each row execute function public.block_if_banned();

drop trigger if exists trg_block_banned_reports on public.reports;
create trigger trg_block_banned_reports before insert on public.reports
  for each row execute function public.block_if_banned();

-- 運営者だけが停止／解除できる。自分自身は停止できない（管理者ロックアウト防止）。
create or replace function public.set_user_ban(target uuid, ban boolean, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '権限がありません'; end if;
  if target = auth.uid() then raise exception '自分自身は停止できません'; end if;
  if (select is_admin from public.profiles where id = target) then
    raise exception '管理者は停止できません';
  end if;
  update public.profiles
     set banned_at = case when ban then now() else null end,
         banned_reason = case when ban then reason else null end
   where id = target;
  -- 本人に通知（理由が分からないまま投稿できなくなる状態を避ける）
  if ban then
    insert into public.notifications(user_id, type, title, body, link)
    values (target, 'system', 'アカウントのご利用停止',
            coalesce(nullif(btrim(reason),''), '利用規約に違反する行為が確認されたため、投稿機能のご利用を停止しました。') ,
            'index.html#feedback');
  else
    insert into public.notifications(user_id, type, title, body, link)
    values (target, 'system', 'ご利用停止を解除しました',
            '投稿機能のご利用を再開いただけます。', 'index.html');
  end if;
end; $$;
revoke all on function public.set_user_ban(uuid, boolean, text) from public, anon;
grant execute on function public.set_user_ban(uuid, boolean, text) to authenticated;   -- 中で is_admin を検査

-- 運営用: 通報の多い投稿者を「確認すべき順」に並べる（★自動処分はしない・判断材料のみ）
create or replace function public.report_summary(limit_n int default 30)
returns table(
  owner_id uuid, user_id text, display_name text,
  report_count bigint, recipe_count bigint, last_report timestamptz,
  distinct_reporters bigint, banned boolean
)
language sql stable security definer set search_path = public as $$
  select r.owner_id,
         p.user_id, p.display_name,
         count(*) as report_count,
         count(distinct rp.recipe_id) as recipe_count,
         max(rp.created_at) as last_report,
         count(distinct rp.reporter_id) as distinct_reporters,   -- 同一人物の連投を見抜くため
         (p.banned_at is not null) as banned
  from public.reports rp
  join public.recipes r on r.id = rp.recipe_id
  join public.profiles p on p.id = r.owner_id
  where public.is_admin()
  group by r.owner_id, p.user_id, p.display_name, p.banned_at
  order by count(distinct rp.reporter_id) desc, count(*) desc, max(rp.created_at) desc
  limit greatest(1, least(coalesce(limit_n,30), 100));
$$;
grant execute on function public.report_summary(int) to authenticated;   -- 中で is_admin を検査

-- 停止状態は本人と管理者だけが読めれば十分（匿名には既に列単位で見せていない）
grant select (banned_at) on public.profiles to authenticated;
