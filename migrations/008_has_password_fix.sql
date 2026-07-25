-- =====================================================================
-- 008_has_password_fix.sql
--   「メール+パスワードで登録したのに、設定画面で『Googleで認証中（パスワード未設定）』と
--    表示され、メールアドレス変更もできない」問題の修正。
--
--   原因: has_password はフロントが登録直後に立てていたが、メール確認ON運用では
--         登録時にセッションが無く、その分岐を通らないため false のままだった。
--   方針: 認証方式はフロントの自己申告ではなく、サーバー(auth.users)の実体から確定する。
--   ※ Supabase ダッシュボードの SQL Editor で実行してください（007 の後）。冪等。
-- =====================================================================

-- (1) 新規ユーザー: パスワードを持って作られたかを auth.users から判定して profiles に記録
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, has_password)
  values (new.id, (new.encrypted_password is not null and new.encrypted_password <> ''))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- (2) パスワードが後から設定/変更されたときも追従する（再設定メールからの設定を含む）
create or replace function public.sync_has_password()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if NEW.encrypted_password is distinct from OLD.encrypted_password then
    update public.profiles
       set has_password = (NEW.encrypted_password is not null and NEW.encrypted_password <> '')
     where id = NEW.id;
  end if;
  return NEW;
end; $$;

drop trigger if exists on_auth_user_password_changed on auth.users;
create trigger on_auth_user_password_changed
  after update on auth.users
  for each row execute function public.sync_has_password();

-- (3) 既存ユーザーの補正（誤って false のままの人を実体に合わせる）
update public.profiles p
   set has_password = (u.encrypted_password is not null and u.encrypted_password <> '')
  from auth.users u
 where u.id = p.id
   and p.has_password is distinct from (u.encrypted_password is not null and u.encrypted_password <> '');
