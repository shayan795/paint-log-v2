-- ============================================================================
-- 027/028: BAN隔離の範囲を正しく絞る（025の修正）※本番適用済み(2026-08-01)
-- ----------------------------------------------------------------------------
-- 025で2つ行き過ぎがあり、DBテストが検出した。
--
-- (1) 管理者に「他人の非公開投稿を読む権限」まで与えてしまっていた
--     BANした人の投稿を隠すのが目的で、運営が誰の非公開レシピでも覗ける状態にする
--     意図は無かった。非公開は「自分だけのもの」という約束なので、運営でも見えない方が正しい。
--     → 管理者の例外は「公開投稿に限る」に絞った（停止中の公開投稿だけ確認できる）。
--
-- (2) コメントの読み取りに user_id = auth.uid() を独立して足してしまい、
--     「非公開にされた投稿のコメントは誰からも見えない」という元の仕様を崩していた。
--     投稿者が非公開に切り替えたのにコメントだけ生き残るのは「非公開」の約束に反する。
--     → 投稿が見えないならコメントも見えない、という元の考え方に戻した。
--
-- ★どちらもDBテスト605本が不合格として教えてくれたもの。
--   テストを甘くして通すのではなく、実装の行き過ぎを戻した。
-- ============================================================================
drop policy if exists recipes_select on public.recipes;
create policy recipes_select on public.recipes for select using (
  owner_id = auth.uid()
  or (is_public and (not public.owner_is_banned(owner_id) or public.is_admin()))
);

drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments for select using (
  (not public.owner_is_banned(user_id) or public.is_admin())
  and exists (
    select 1 from public.recipes r
     where r.id = comments.recipe_id
       and (r.owner_id = auth.uid()
            or (r.is_public and (not public.owner_is_banned(r.owner_id) or public.is_admin())))
  )
);
