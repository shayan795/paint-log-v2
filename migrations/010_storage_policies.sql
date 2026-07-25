-- =====================================================================
-- 010_storage_policies.sql
--   ★情報漏えいの修正（公開前の最優先）★
--
--   問題: storage.objects の SELECT ポリシーが recipes_img_read / profile_read という
--         「bucket_id が一致すれば誰でも読める」定義になっており、匿名の公開キーだけで
--         POST /storage/v1/object/list/<bucket> を叩くと全ユーザーのファイルが列挙できた。
--         → URLを知らない第三者でも「非公開投稿・下書きの写真」に到達できる状態
--           （プライバシーポリシーの「非公開投稿は他者に公開しません」と矛盾）。
--
--   対策: 一覧・メタデータの参照は「本人のファイルのみ」に限定する。
--
--   ★表示は壊れない: recipes / profile は public バケットのため、画像の実配信は
--     /storage/v1/object/public/... 経由で RLS を通らない。公開レシピのサムネ・カバー・
--     OGP画像は今まで通り表示される（適用後に実測で確認すること）。
--     退会処理の profile 一覧取得は本人＝authenticated なので下記ポリシーで動作する。
--
--   ※ Storageの権限はこれまでリポジトリに存在せずダッシュボード手動設定のみだった。
--     今回の見落としの根本原因なので、以後はこのファイルで管理する。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（009 の後）。冪等。
-- =====================================================================

-- 旧: バケットが一致すれば誰でも読める（＝全件列挙できた）
drop policy if exists recipes_img_read on storage.objects;
drop policy if exists profile_read     on storage.objects;

-- 新: 自分のフォルダ（先頭が自分のUUID）のファイルだけ参照できる
drop policy if exists objects_select_own on storage.objects;
create policy objects_select_own on storage.objects
  for select to authenticated
  using (
    bucket_id in ('recipes','profile')
    and (
      owner = auth.uid()
      or (storage.foldername(name))[1] = auth.uid()::text
    )
  );

-- 書き込み系（recipes_img_write / profile_write）は従来どおり owner = auth.uid() のまま。
-- 参考: 現状の定義を明示的に残しておく（冪等・内容は変更していない）
drop policy if exists recipes_img_write on storage.objects;
create policy recipes_img_write on storage.objects
  for all using (bucket_id = 'recipes' and owner = auth.uid())
  with check (bucket_id = 'recipes' and owner = auth.uid());

drop policy if exists profile_write on storage.objects;
create policy profile_write on storage.objects
  for all using (bucket_id = 'profile' and owner = auth.uid())
  with check (bucket_id = 'profile' and owner = auth.uid());
