-- ============================================================================
-- 037: 既存投稿の表紙を「合成カード」から「1枚目の写真」へ切り替える
--
-- ★★ このファイルだけは実行の順番が違う ★★
--   035・036 とは違い、**新しいコードを公開して、行き渡ってから** 実行すること。
--
--   正しい順番:
--     1. 035 を実行（列の追加・共有カードの保護）      ← 旧コードのままでも安全
--     2. 036 を実行（投稿削除で共有カードも消す）        ← 同上
--     3. 新しい legacy.html / index.html / Worker を公開
--     4. 公開から15分以上あける（古い画面を開いている人がいなくなるのを待つ）
--     5. ★このファイルを実行
--
-- ★なぜ待つ必要があるのか（実際に確認した消失経路）
--   公開中の legacy.html には silentRefreshCover があり、投稿者が自分の投稿を開くと
--   古い表紙を **参照確認なしで** Storage から消す:
--       sb.storage.from("recipes").remove([oldPath])
--   このファイルを先に流すと、その oldPath が「本文で使っている1枚目の写真」になる。
--   つまり **投稿者が自分の投稿を開いた瞬間に、その写真が永久に消える。**
--   エラーもログも出ないので、誰かに指摘されるまで気づけない。
--   抑止用の localStorage の印は端末ごとなので、別のブラウザなら必ず再発する。
--
--   新しい legacy.html ではこの処理を停止済み。だから「コードが先、データは後」。
--
-- ★何度実行しても同じ結果になる（冪等）。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) いまの表紙（文字入りの合成カード）を、SNS共有用として退避する
-- ----------------------------------------------------------------------------
update public.recipes
   set share_url = cover_url
 where share_url is null
   and cover_url is not null
   and cover_url like '%_cover.jpg';

-- ----------------------------------------------------------------------------
-- (2) 表紙を「1枚目の写真」に付け替える
-- ----------------------------------------------------------------------------
-- 写真が無い投稿は合成カードのままにする。
-- （表紙が無い投稿は、おすすめ・塗料ページ・タグ結果から丸ごと消えてしまうため）
update public.recipes
   set cover_url = grid->'photos'->>0
 where grid->'photos'->>0 is not null;

-- ----------------------------------------------------------------------------
-- (3) 自己点検：本当に切り替わったかを数えて確認する
-- ----------------------------------------------------------------------------
-- ★035の点検は「列があるか」しか見ておらず、引っ越しが0件でも成功と出た。
--   ここでは実際の件数を見て、想定と食い違えば止める。
do $$
declare
  need int; done int; guard text;
begin
  -- 共有カードの保護（035）が入っていないと、この直後の掃除でカードが消える
  guard := coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                       join pg_namespace n on n.oid=p.pronamespace
                      where n.nspname='public' and p.proname='purge_unreferenced_images'), '');
  if guard not like '%share_url%' then
    raise exception '先に 035 を実行してください（共有カードが自動削除から守られていません）';
  end if;

  select count(*) into need from public.recipes where grid->'photos'->>0 is not null;
  select count(*) into done from public.recipes
   where grid->'photos'->>0 is not null and cover_url = grid->'photos'->>0;
  if need <> done then
    raise exception '表紙の切り替えが完了していません（対象%件 / 完了%件）', need, done;
  end if;
  raise notice '037: 表紙を写真へ切り替えました（%件）', done;
end $$;
