-- =====================================================================
-- Phase 3: 検索のサーバーサイド化
--   現状は「公開recipesを新着300件fetch→クライアント側フィルタ」のため、
--   投稿が300件を超えると古いレシピが検索不能になる。Postgres側のRPCに置換。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください。
-- =====================================================================

create extension if not exists pg_trgm;

-- title の部分一致(ILIKE)を高速化する trigram インデックス
create index if not exists idx_recipes_title_trgm
  on public.recipes using gin (title gin_trgm_ops);

-- 検索RPC：security invoker（呼び出し元権限＝RLSが効く）＋ 内部で is_public=true を強制。
-- 検索対象：title 部分一致 / methods(タグ)配列 / grid内テキスト(自由入力塗料名など)。
-- grid::text ILIKE は簡易実装。将来遅ければ recipe_paints 等への正規化を検討する。
create or replace function public.search_recipes(_q text, _limit int default 50)
returns table(
  id uuid, title text, cover_url text, is_public boolean, created_at timestamptz,
  methods jsonb, grid jsonb, owner_id uuid, match_reason text
)
language sql stable security invoker set search_path = public as $$
  with q as (
    -- LIKE のワイルドカード( % _ \ )をエスケープしてから前後に % を付ける
    select '%' || replace(replace(replace(coalesce(_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%' as like_q
  )
  select
    r.id, r.title, r.cover_url, r.is_public, r.created_at,
    to_jsonb(r.methods) as methods, r.grid, r.owner_id,
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
  limit greatest(1, least(coalesce(_limit, 50), 100));
$$;

grant execute on function public.search_recipes(text, int) to anon, authenticated;
