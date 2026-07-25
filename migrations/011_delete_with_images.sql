-- =====================================================================
-- 011_delete_with_images.sql
--   投稿・下書きの削除を「本文＋画像」まとめてサーバー側で行うRPCを追加する。
--
--   これまでの問題:
--     (1) 管理者が通報対応で他人の投稿を消しても、画像だけ公開URLに残り続けた。
--         クライアントの storage.remove は所有者しか通らず(書き込みポリシーが owner 限定)、
--         しかも失敗を確認していなかったため「削除しました」が事実にならなかった。
--         → 削除請求・権利侵害対応で「送信防止措置を講じた」と言えない状態。
--     (2) 削除順が「画像→本文」で、本文の削除に失敗すると画像だけ永久に消える
--         （写真はバックアップ対象外なので復元不能）。
--     (3) 下書きを削除しても画像が残り続けた。
--
--   対策: SECURITY DEFINER のRPCで、権限確認 → 画像削除 → 本文削除 を1トランザクションで行う。
--         どこかで失敗すれば全部巻き戻る（＝画像だけ消える事故が起きない）。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（010 の後）。冪等。
-- =====================================================================

-- 公開URL → Storage内のパスを取り出す（recipes バケット）
create or replace function public.storage_path_from_url(u text)
returns text language sql immutable as $$
  select nullif(substring(coalesce(u,'') from '/object/public/recipes/(.*)$'), '');
$$;

-- 投稿を画像ごと削除する。実行できるのは「投稿者本人」または「管理者」。
create or replace function public.delete_recipe_with_images(rid uuid)
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare r record; paths text[];
begin
  select owner_id, cover_url, grid into r from public.recipes where id = rid;
  if not found then raise exception '投稿が見つかりません'; end if;
  if r.owner_id <> auth.uid() and not public.is_admin() then
    raise exception 'この投稿を削除する権限がありません';
  end if;

  -- 本文(grid)とカバーから画像パスを集める
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

  delete from public.recipes where id = rid;   -- 本文は最後（画像だけ消える事故を防ぐ）
end; $$;
grant execute on function public.delete_recipe_with_images(uuid) to authenticated;

-- 下書きを画像ごと削除する。本人のみ。
create or replace function public.delete_draft_with_images(did uuid)
returns void language plpgsql security definer set search_path to 'public','auth','storage' as $$
declare d record; paths text[];
begin
  select owner_id, cover_url, grid into d from public.drafts where id = did;
  if not found then return; end if;
  if d.owner_id <> auth.uid() then raise exception 'この下書きを削除する権限がありません'; end if;

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

  -- ★下書きの画像は、投稿として公開済みのものと同じURLを共有していることがある
  --   （下書き→投稿の昇格時にURLを流用するため）。現存するレシピが参照している画像は消さない。
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
grant execute on function public.delete_draft_with_images(uuid) to authenticated;
