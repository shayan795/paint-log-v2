-- ============================================================================
-- 025: 停止(BAN)中の利用者の投稿・コメントを公開の場から隠す【#7】
-- ※ Supabase の SQL Editor で実行してください（024の後）。冪等。※本番適用済み(2026-08-01)
-- ----------------------------------------------------------------------------
-- ★これまでBANは「これ以上書けなくする」だけで、既に公開されている投稿は
--   一覧・検索・共有URL・sitemapから見え続けていた。
--   権利侵害や違法な画像を投稿した人を止めても被害が続き、
--   オーナー1人が手作業で全部消すまで公開されたままだった。
-- ★「消す」のではなく「隠す」にした理由:
--   誤BANを元に戻せる必要があり、通報の証拠としても現物が要るため。
--   本人と管理者からは今までどおり見える（本人の手元からデータは消えない）。
-- ============================================================================
create or replace function public.owner_is_banned(uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles p where p.id = uid and p.banned_at is not null);
$$;
revoke all on function public.owner_is_banned(uuid) from public;
grant execute on function public.owner_is_banned(uuid) to anon, authenticated;

drop policy if exists recipes_select on public.recipes;
create policy recipes_select on public.recipes for select using (
  owner_id = auth.uid() or public.is_admin()
  or (is_public and not public.owner_is_banned(owner_id))
);

drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments for select using (
  user_id = auth.uid() or public.is_admin()
  or (not public.owner_is_banned(user_id)
      and exists (select 1 from public.recipes r
                   where r.id = comments.recipe_id
                     and (r.owner_id = auth.uid()
                          or (r.is_public and not public.owner_is_banned(r.owner_id)))))
);
