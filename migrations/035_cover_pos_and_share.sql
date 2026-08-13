-- ============================================================================
-- 035: 一覧サムネの「中心」と、SNS共有用カードを分けて持つ
-- ※ Supabase の SQL Editor で実行してください（034の後）。冪等。
-- ============================================================================
--
-- ★★ 公開の順序を必ず守ること ★★
--   このSQLを**先に**本番へ流してから、legacy.html / index.html を公開すること。
--   逆順にすると、新しい legacy.html が cover_pos / share_url を送るのに
--   本番のテーブルに列が無く、**投稿と更新が全部失敗する**
--   （PostgRESTは 42703 "column does not exist" を返す）。
--   列を先に足しておけば、古い画面が動いていても何も起きない（NULLのまま）。
--
-- ★何のためか
--   これまで表紙(cover_url)は「塗装レシピ録」の文字入り合成カード1枚が、
--   サイト内の一覧とSNS共有の両方を兼ねていた。その結果:
--     ・一覧がどれも同じ見た目のカードで埋まり、何の作品か分からなかった
--   そこで用途を分ける。
--     cover_url  … サイト内の一覧に出す「写真そのもの」
--     share_url  … SNSに出す「文字入り合成カード」（見栄えがよく出所も伝わる）
--   さらに、一覧のタイルは 4:3 や 1:1 に切り取られるため、
--   写真のどこを中心にするかを投稿者が決められるようにする（cover_pos）。
--   投稿を開いたときは今まで通り写真の全体が出るので、切り取りは一覧だけの話。
-- ============================================================================

alter table public.recipes add column if not exists cover_pos text;
alter table public.recipes add column if not exists share_url text;

comment on column public.recipes.cover_pos is
  '一覧サムネの表示位置。CSSのobject-position用の "50% 30%" 形式。空なら中央。投稿本文の見え方には影響しない。';
comment on column public.recipes.share_url is
  'SNS共有(OGP)に使う画像。文字入りの合成カード。サイト内の一覧には使わない。';

-- ★形を厳しく縛る。
--   cover_pos は画面側で CSS の object-position にそのまま渡る値なので、
--   自由な文字列を許すと、投稿者がAPIを直接叩いて別の指定を紛れ込ませられる。
--   「数字% 数字%」以外は保存できないようにして、入口で断つ。
alter table public.recipes drop constraint if exists recipes_cover_pos_fmt;
alter table public.recipes add constraint recipes_cover_pos_fmt
  check (cover_pos is null or cover_pos ~ '^[0-9]{1,3}% [0-9]{1,3}%$');

-- ----------------------------------------------------------------------------
-- ★引っ越しの前に、共有カードを「使用中の画像」として守る
-- ----------------------------------------------------------------------------
-- これを先にやらないと、次の UPDATE で share_url に入れた合成カードが
-- 「どこからも参照されていない画像」と判定され、自動掃除で消える。
-- データベースにはURLだけが残り、実体だけが消えるので、
-- SNSの共有プレビューが全部「画像なし」になる。エラーもログも出ない。
--
-- ★当初これを別ファイル(036)に分け「036を先に流せ」と書いていたが、それは誤り。
--   036を先に流すと、share_url 列がまだ無い状態で削除処理が share_url を参照するため、
--   035を流すまでの間ずっと「投稿の削除」が失敗する。
--   つまり2つに分けた時点で、**安全な実行順が存在しない**状態を作っていた。
--   番号順に流せば安全、という当たり前の規律を壊してはいけない。
create or replace function public.purge_unreferenced_images(p_owner uuid)
returns integer language plpgsql security definer
set search_path to 'public', 'auth', 'storage' as $function$
declare n int := 0;
begin
  if p_owner is null then return 0; end if;
  perform set_config('storage.allow_delete_query', 'true', true);
  with used as (
    select public.storage_path_of(cover_url,'recipes') as p from public.recipes where owner_id = p_owner
    union all
    select public.storage_path_of(share_url,'recipes') from public.recipes where owner_id = p_owner
    union all
    select public.storage_path_of(x,'recipes') from public.recipes r,
      jsonb_array_elements_text(case when jsonb_typeof(r.grid->'photos')='array' then r.grid->'photos' else '[]'::jsonb end) x
      where r.owner_id = p_owner
    union all
    select public.storage_path_of(e->>'photo','recipes') from public.recipes r,
      jsonb_array_elements(case when jsonb_typeof(r.grid->'rows')='array' then r.grid->'rows' else '[]'::jsonb end) e
      where r.owner_id = p_owner
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
       and o.created_at < now() - interval '1 hour'
       and o.name not in (select p from used where p is not null)
    returning 1
  )
  select count(*) into n from del;
  return n;
end; $function$;

-- ----------------------------------------------------------------------------
-- 既存投稿の引っ越しは 037 へ分離した
-- ----------------------------------------------------------------------------
-- ★ここに書いていたUPDATE 2本は 037_switch_covers_to_photos.sql へ移した。
--   理由は「利用者の完成写真が永久に消える」経路があったため。
--
--   いま公開中の legacy.html には silentRefreshCover という処理があり、
--   投稿者が自分の投稿を開くと、古い表紙を **参照確認なしで** Storage から削除する。
--     sb.storage.from("recipes").remove([oldPath])
--   ここで cover_url を「1枚目の写真」に付け替えてしまうと、その oldPath が
--   まさに本文で使っている写真そのものになる。つまり、
--   **表紙を切り替えた直後に投稿者が自分の投稿を開いた瞬間、その写真が消える。**
--   エラーもログも出ず、写真は元に戻せない。
--
--   新しい legacy.html ではこの処理を止めてある。だから
--   「新しいコードが行き渡ってから引っ越す」順にしなければならない。
--   このファイル(035)は、旧コードが動いている状態で流しても何も壊れない範囲だけにした。
--
-- ----------------------------------------------------------------------------
-- 自己点検：入っていなければ止める
-- ----------------------------------------------------------------------------
do $$
declare miss text := '';
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='recipes' and column_name='cover_pos')
    then miss := miss || 'cover_pos列 '; end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='recipes' and column_name='share_url')
    then miss := miss || 'share_url列 '; end if;
  if not exists (select 1 from pg_constraint where conname='recipes_cover_pos_fmt')
    then miss := miss || '形の制約 '; end if;
  -- ★共有カードが守られていることまで確認する。
  --   ここを見ていないと「列は入ったが画像は消える」状態で成功扱いになる。
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='purge_unreferenced_images') not like '%share_url%'
    then miss := miss || '共有カードの保護 '; end if;
  if miss <> '' then raise exception '035が完全に適用されていません: %', miss; end if;
  raise notice '035: すべて適用されました';
end $$;
