-- =====================================================================
-- 012_scale_guards.sql
--   告知（人が増える）に備えた帯域・容量・スパム対策。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（011 の後）。冪等。
-- =====================================================================

-- ---------------------------------------------------------------------
-- (1) 検索が「レシピ本文(grid)」まで返していたのを止める【帯域】
--   grid は1件あたり数KB〜で、100件返すと数百KB。しかもクライアントはRPC経路では
--   grid を一切使っていない（カード表示に使うのは id/title/cover_url だけ）。
--   無料枠の転送量(5GB/月)を無駄に食うので返却列から外し、上限も現実的な値に下げる。
-- ---------------------------------------------------------------------
drop function if exists public.search_recipes(text, int);
create or replace function public.search_recipes(_q text, _limit int default 20)
returns table(
  id uuid, title text, cover_url text, is_public boolean, created_at timestamptz,
  methods jsonb, owner_id uuid, match_reason text
)
language sql stable security invoker set search_path = public as $$
  with q as (
    select '%' || replace(replace(replace(coalesce(_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%' as like_q
  )
  select
    r.id, r.title, r.cover_url, r.is_public, r.created_at,
    to_jsonb(r.methods) as methods, r.owner_id,
    case
      when r.title ilike (select like_q from q) then 'title'
      when exists (
        select 1 from jsonb_array_elements_text(to_jsonb(r.methods)) m
        where m ilike (select like_q from q)
      ) then 'tag'
      else 'paint'
    end as match_reason
  from public.recipes r, q
  where r.is_public = true
    and (
      r.title ilike q.like_q
      or exists (
        select 1 from jsonb_array_elements_text(to_jsonb(r.methods)) m
        where m ilike q.like_q
      )
      or r.grid::text ilike q.like_q
    )
  order by (r.title ilike q.like_q) desc, r.created_at desc
  limit greatest(1, least(coalesce(_limit, 20), 50));
$$;
grant execute on function public.search_recipes(text, int) to anon, authenticated;

-- ---------------------------------------------------------------------
-- (2) 投稿のレート制限【スパム・容量】
--   コメントには30秒制限があるのに、投稿と画像アップロードは無制限だった。
--   告知後に自動投稿を流されると、DB容量(500MB)とStorage(1GB)を一気に消費される。
--   同一ユーザー: 20秒間隔 かつ 1日30件 まで（通常の利用ではまず当たらない値）。
-- ---------------------------------------------------------------------
create or replace function public.check_recipe_rate()
returns trigger language plpgsql security definer set search_path = public as $$
declare last_at timestamptz; cnt_today int;
begin
  if auth.uid() is null then return NEW; end if;   -- 管理・移行用の直接操作は対象外
  perform pg_advisory_xact_lock(hashtextextended(NEW.owner_id::text, 0));   -- 同時実行での擦り抜け防止
  select max(created_at) into last_at from public.recipes where owner_id = NEW.owner_id;
  if last_at is not null and last_at > now() - interval '20 seconds' then
    raise exception '投稿の間隔が短すぎます。少し待ってからお試しください。';
  end if;
  select count(*) into cnt_today from public.recipes
   where owner_id = NEW.owner_id and created_at > now() - interval '1 day';
  if cnt_today >= 30 then
    raise exception '1日に投稿できる件数の上限に達しました。時間をおいてお試しください。';
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_check_recipe_rate on public.recipes;
create trigger trg_check_recipe_rate before insert on public.recipes
  for each row execute function public.check_recipe_rate();

-- ---------------------------------------------------------------------
-- (3) 古いデータの自動掃除を「実際に動く」ようにする【容量】
--   purge_old_events() は作ってあるが一度も実行されていない（pg_cron未導入のため）。
--   pg_cron を有効化して毎日 JST 3:00 (UTC 18:00) に実行する。
--   ※ 環境によっては拡張の作成に権限が必要。失敗する場合はダッシュボードの
--     Database > Extensions で pg_cron を有効化してから、下の cron.schedule だけ実行する。
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule('purge-old-events');
exception when others then null;   -- 未登録なら無視
end $$;

select cron.schedule('purge-old-events', '0 18 * * *', $$ select public.purge_old_events(); $$);
