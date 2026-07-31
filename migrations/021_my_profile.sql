-- ============================================================================
-- 021: 自分のプロフィールを自分で読めるようにする
-- ※ Supabase の SQL Editor で実行してください（020の後）。冪等。
-- ----------------------------------------------------------------------------
-- ★何が起きていたか（2026-08-01に発覚）
--   設定画面で「表示名」「ユーザーID」が、実際には設定されているのに
--   すべて「未設定」と表示されていた。
--
--   原因は列の読み取り権限。profiles は SELECT ポリシーが `true`（誰でも全行読める）なので、
--   内部的な列は「列ごと権限を外す」ことで守っている（004/007/016）。
--   その結果 notify_comments / is_admin / terms_agreed_at は authenticated でも読めない。
--   ところが設定画面は notify_comments を含めて4列まとめて読んでいたため、
--   **問い合わせ全体が permission denied で失敗**し、表示名もユーザーIDも空になっていた。
--   エラーは画面に出ず「未設定」と表示されるだけなので、非常に気づきにくかった。
--   同じ理由で「投稿データの控えを保存する」(select *) も失敗していた。
--
-- ★なぜ単純に GRANT しないか
--   profiles は誰でも全行読めるため、列に GRANT すると
--   **他人の通知設定まで全員に見える**ことになる。
--   自分の行だけを返す関数を用意し、そこからだけ読めるようにする。
-- ============================================================================

-- 自分自身のプロフィール（内部列を含む）を返す。
-- security definer だが、返すのは必ず auth.uid() の行だけなので他人の情報は出ない。
create or replace function public.my_profile()
returns table (
  id              uuid,
  user_id         text,
  display_name    text,
  avatar_url      text,
  header_url      text,
  bio             text,
  link            text,
  x_account       text,
  has_password    boolean,
  notify_comments boolean,
  terms_agreed_at timestamptz,
  is_admin        boolean,
  banned_at       timestamptz,
  created_at      timestamptz
)
language sql
security definer
set search_path to 'public','auth'
as $$
  select p.id, p.user_id, p.display_name, p.avatar_url, p.header_url, p.bio, p.link,
         p.x_account, p.has_password, p.notify_comments, p.terms_agreed_at,
         p.is_admin, p.banned_at, p.created_at
    from public.profiles p
   where p.id = auth.uid()      -- ★ここが要。呼んだ本人の行しか返さない
   limit 1;
$$;

-- 匿名からは呼べないようにする（auth.uid() が null なら0件だが、原則どおり閉じる）
revoke all on function public.my_profile() from public, anon;
grant execute on function public.my_profile() to authenticated;

comment on function public.my_profile() is
  '設定画面などで「自分自身の」プロフィールを内部列込みで取得する。profiles は誰でも全行読める設定のため、内部列は列権限で塞いである。その代わりの入口。他人の行は絶対に返さない。';
