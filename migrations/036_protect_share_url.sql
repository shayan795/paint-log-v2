-- ============================================================================
-- 036: 投稿を削除したとき、SNS共有カード(share_url)も一緒に消す
-- ※ Supabase の SQL Editor で **035 の後に** 実行してください。番号順でOK。
-- ============================================================================
--
-- ★当初このファイルの見出しには「035より先に流すこと」と書いていた。これは誤り。
--   share_url 列がまだ無い状態でこの関数を作ると、列ができるまでの間
--   「投稿の削除」が必ず失敗する（関数の作成自体は通るが、実行時に列が無くて落ちる）。
--   一方で035を先に流すと共有カードが消える、という別の穴があったため、
--   **どちらの順でも壊れる**状態になっていた。
--   自動掃除から守る部分は035へ移し、このファイルは削除処理だけにした。
--   これで「番号順に流せば安全」という当たり前の規律に戻る。
-- ============================================================================
--
-- ★何が起きるか（これを入れないと）
--   035 で share_url に合成カードのURLを入れると、そのファイルは
--   「どこからも参照されていない画像」と judged されて自動削除の対象になる。
--   結果、データベースにはURLだけが残り、実体だけが消える。
--   X や LINE の共有プレビューが全部「画像なし」になるが、
--   **エラーもログも一切出ない**ので、誰かに指摘されるまで気づけない。
--
--   同じ理由で、投稿を削除しても share_url のカードだけが消し残る。
--   そのカードには完成写真・作品名・制作者名が焼き込まれているため、
--   「写真も含めて削除しました」と表示しながら、URLを知る人には見え続ける。
--
-- ★purge_orphan_storage は変更不要
--   あれは「アカウントごと消えた人のフォルダ」を片付ける処理で、
--   参照の有無を見ていない。share_url とは無関係。実際に定義を読んで確認済み。
--
-- ★この2つの関数は、いま本番で動いている定義をそのまま写して、
--   share_url の行だけを足している。頭の中で書き直していない。
--   （以前、理想形で書き直した移行ファイルが実物と食い違い、復旧が壊れる状態を作った）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (2) 投稿を削除したとき、共有カードも一緒に消す
-- ----------------------------------------------------------------------------
create or replace function public.delete_recipe_with_images(rid uuid)
returns void language plpgsql security definer
set search_path to 'public', 'auth', 'storage' as $function$
declare r record; paths text[]; me uuid := auth.uid();
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  -- ★036で追加：share_url も取り出す
  select owner_id, cover_url, share_url, grid into r from public.recipes where id = rid;
  if not found then raise exception '投稿が見つかりません'; end if;
  if r.owner_id is distinct from me and not public.is_admin() then
    raise exception 'この投稿を削除する権限がありません';
  end if;
  select array_remove(array_agg(distinct p), null) into paths from (
    select public.storage_path_from_url(r.cover_url) as p
    union all
    -- ★036で追加：共有カードも削除対象にする
    select public.storage_path_from_url(r.share_url)
    union all
    select public.storage_path_from_url(x) from jsonb_array_elements_text(
      case when jsonb_typeof(r.grid->'photos') = 'array' then r.grid->'photos' else '[]'::jsonb end) as x
    union all
    select public.storage_path_from_url(row_elem->>'photo')
      from jsonb_array_elements(
        case when jsonb_typeof(r.grid->'rows') = 'array' then r.grid->'rows' else '[]'::jsonb end) as row_elem
  ) s;
  if paths is not null and array_length(paths,1) > 0 then
    select array_remove(array_agg(p), null) into paths from unnest(paths) as p
     where split_part(p, '/', 1) = r.owner_id::text;
  end if;
  if paths is not null and array_length(paths,1) > 0 then
    select array_remove(array_agg(p), null) into paths from unnest(paths) as p
     where not exists (
       select 1 from public.recipes o
        where o.id <> rid
          -- ★036で追加：他の投稿が share_url として使っていれば消さない
          and (public.storage_path_from_url(o.cover_url) = p
               or public.storage_path_from_url(o.share_url) = p
               or o.grid::text like '%'||p||'%')
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
end; $function$;

-- ----------------------------------------------------------------------------
-- (3) 自己点検
-- ----------------------------------------------------------------------------
do $$
declare miss text := '';
begin
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='purge_unreferenced_images') not like '%share_url%'
    then miss := miss || '自動掃除 '; end if;
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='delete_recipe_with_images') not like '%share_url%'
    then miss := miss || '投稿削除 '; end if;
  if miss <> '' then raise exception '036が完全に適用されていません: %', miss; end if;
  raise notice '036: 共有カードを守る設定が入りました';
end $$;
