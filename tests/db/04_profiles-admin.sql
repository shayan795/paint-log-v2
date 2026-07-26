-- 権限:プロフィール のテスト（自動生成・dev専用）
do $$
declare
  a    text := '権限:プロフィール';
  u1   uuid; u2 uuid; u3 uuid; adm uuid; adm2 uuid;
  n1   text; n2 text;
  b    boolean; t timestamptz; s text; err text;
  c0   int; c1 int;
begin
  ---------------------------------------------------------------- 下準備
  perform tests.as_owner();
  -- 後片付けが効いているかを最後に確かめるため、実行前のテスト用利用者数を控える
  select count(*) into c0 from auth.users where email like 'test\_%@example.test';
  u1   := tests.make_user();          -- 一般利用者A（user_id設定済み）
  u2   := tests.make_user();          -- 一般利用者B（user_id未設定）
  u3   := tests.make_user();          -- プロフィール行が欠けている利用者
  adm  := tests.make_user(true);      -- 管理者
  adm2 := tests.make_user(true);      -- もう1人の管理者

  n1 := 'tu_' || substr(replace(u1::text,'-',''), 1, 10);   -- 13文字・英数と_のみ
  n2 := 'u'   || substr(replace(u2::text,'-',''), 1, 19);   -- ちょうど20文字

  update public.profiles
     set display_name = 'テスト太郎', bio = 'はじめまして',
         user_id = n1, has_password = false, notify_comments = true
   where id = u1;

  delete from public.profiles where id = u3;   -- 「プロフィール行が無い利用者」を作る

  -------------------------------------------------- 本人による自分の編集
  perform tests.as_user(u1);
  perform tests.affects(a, '本人は自分の表示名(display_name)を更新できる',
    format('update public.profiles set display_name = ''新しい表示名'' where id = %L', u1), 1);
  perform tests.affects(a, '本人は自己紹介・リンク・Xアカウントを更新できる',
    format('update public.profiles set bio = ''自己紹介です'', link = ''https://example.test'', x_account = ''@example'' where id = %L', u1), 1);
  perform tests.affects(a, '本人はアイコン画像・ヘッダー画像のURLを更新できる',
    format('update public.profiles set avatar_url = ''https://img.test/a.jpg'', header_url = ''https://img.test/h.jpg'' where id = %L', u1), 1);
  perform tests.affects(a, '本人はコメント通知の設定(notify_comments)を切り替えられる',
    format('update public.profiles set notify_comments = false where id = %L', u1), 1);
  perform tests.affects(a, '本人は規約同意の時刻(terms_agreed_at)を記録できる',
    format('update public.profiles set terms_agreed_at = now() where id = %L', u1), 1);

  perform tests.as_owner();
  select display_name into s from public.profiles where id = u1;
  perform tests.eq(a, '本人の更新内容が実際に保存されている', s, '新しい表示名');

  ------------------------------------------ 他人・匿名からの書き換え防止
  perform tests.as_user(u2);
  perform tests.affects(a, '他人の表示名は書き換えられない(RLSで0件)',
    format('update public.profiles set display_name = ''乗っ取り'' where id = %L', u1), 0);
  perform tests.affects(a, '他人の自己紹介・リンクは書き換えられない(RLSで0件)',
    format('update public.profiles set bio = ''改ざん'', link = ''https://evil.test'' where id = %L', u1), 0);
  perform tests.affects(a, '他人のアイコン画像URLは書き換えられない(RLSで0件)',
    format('update public.profiles set avatar_url = ''https://evil.test/x.jpg'' where id = %L', u1), 0);
  perform tests.affects(a, '他人のプロフィール行は削除できない(RLSで0件)',
    format('delete from public.profiles where id = %L', u1), 0);
  perform tests.affects(a, '本人でもプロフィール行そのものは削除できない(削除ポリシーが無い)',
    format('delete from public.profiles where id = %L', u2), 0);
  perform tests.denied(a, '他人のidでプロフィール行を新規作成できない',
    format('insert into public.profiles(id, display_name) values (%L, ''なりすまし'')', u3),
    'row-level security');
  perform tests.denied(a, '自分の行のidを別のidに書き換えられない',
    format('update public.profiles set id = gen_random_uuid() where id = %L', u2),
    'row-level security');

  perform tests.as_anon();
  perform tests.affects(a, '匿名は誰の表示名も書き換えられない(RLSで0件)',
    format('update public.profiles set display_name = ''匿名改ざん'' where id = %L', u1), 0);
  perform tests.affects(a, '匿名はプロフィール行を削除できない(RLSで0件)',
    format('delete from public.profiles where id = %L', u1), 0);
  perform tests.denied(a, '匿名はプロフィール行を新規作成できない',
    format('insert into public.profiles(id, display_name) values (%L, ''匿名作成'')', u3),
    'row-level security');

  ------------------------------------------------ 管理者フラグ(権限昇格)
  perform tests.as_user(u1);
  perform tests.allowed(a, '自分のis_adminをtrueにする更新自体はエラーにならない(黙って無効化される仕様)',
    format('update public.profiles set is_admin = true where id = %L', u1));
  perform tests.as_owner();
  select is_admin into b from public.profiles where id = u1;
  perform tests.eq(a, '一般利用者が自分のis_adminをtrueにしても管理者にならない', b, false);

  perform tests.as_user(u1);
  select public.is_admin() into b;
  perform tests.as_owner();
  perform tests.eq(a, 'is_admin()は一般利用者に対してfalseを返す', b, false);

  perform tests.as_user(adm);
  select public.is_admin() into b;
  perform tests.as_owner();
  perform tests.eq(a, 'is_admin()は管理者に対してtrueを返す', b, true);

  perform tests.as_anon();
  select public.is_admin() into b;
  perform tests.as_owner();
  perform tests.eq(a, 'is_admin()は匿名に対してfalseを返す', b, false);

  perform tests.as_user(u1);
  perform tests.affects(a, '一般利用者は他人を管理者に昇格できない(RLSで0件)',
    format('update public.profiles set is_admin = true where id = %L', u2), 0);

  perform tests.as_user(adm);
  perform tests.affects(a, '管理者でも他人のis_adminはRLSにより書き換えられない(0件)',
    format('update public.profiles set is_admin = true where id = %L', u2), 0);
  perform tests.allowed(a, '管理者が自分のis_adminをfalseにする更新はエラーにならない',
    format('update public.profiles set is_admin = false where id = %L', adm));
  perform tests.as_owner();
  select is_admin into b from public.profiles where id = adm;
  perform tests.eq(a, '管理者が自分のis_adminをfalseにしても管理者のまま(自己降格も無効化)', b, true);

  -- プロフィール行が無い利用者が is_admin=true で自分の行を作ろうとする
  perform tests.as_user(u3);
  begin
    execute format('insert into public.profiles(id, is_admin, display_name) values (%L, true, ''昇格ねらい'')', u3);
    err := null;
  exception when others then
    err := sqlerrm;
  end;
  perform tests.as_owner();
  select is_admin into b from public.profiles where id = u3;
  perform tests.ok(a, 'プロフィール欠損ユーザーがis_admin=trueで行を作っても管理者にならない',
    err is not null or coalesce(b, false) = false,
    '作成時のis_admin=trueがそのまま通ってしまいました(エラー=' || coalesce(err,'なし') || ')');
  perform tests.ok(a, '同ユーザーのプロフィール行が作成できた場合でもis_adminはfalseである',
    coalesce(b, false) = false, '作成された行のis_adminがtrueになっています');

  perform tests.as_user(u1);
  perform tests.denied(a, '一般利用者はset_user_ban()を実行できない',
    format('select public.set_user_ban(%L, true, ''テスト'')', u2), '権限がありません');
  perform tests.as_user(adm);
  perform tests.denied(a, '管理者は自分自身を停止できない(ロックアウト防止)',
    format('select public.set_user_ban(%L, true, ''テスト'')', adm), '自分自身は停止できません');
  perform tests.denied(a, '管理者は他の管理者を停止できない',
    format('select public.set_user_ban(%L, true, ''テスト'')', adm2), '管理者は停止できません');

  -------------------------------------------------- user_id(公開ユーザーID)
  perform tests.as_user(u2);
  perform tests.denied(a, '記号入りのuser_idは形式違反で弾かれる',
    format('update public.profiles set user_id = ''bad!name'' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, '空白入りのuser_idは形式違反で弾かれる',
    format('update public.profiles set user_id = ''bad name'' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, '1文字のuser_idは短すぎて弾かれる',
    format('update public.profiles set user_id = ''a'' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, '21文字のuser_idは長すぎて弾かれる',
    format('update public.profiles set user_id = ''abcdefghijklmnopqrstu'' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, '日本語のuser_idは弾かれる',
    format('update public.profiles set user_id = ''ユーザー名'' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, '空文字のuser_idは弾かれる',
    format('update public.profiles set user_id = '''' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, 'ハイフン入りのuser_idは弾かれる(英数と_のみ許可)',
    format('update public.profiles set user_id = ''bad-name'' where id = %L', u2), 'profiles_user_id_format');
  perform tests.denied(a, '大文字小文字違いの同名user_idは重複として弾かれる',
    format('update public.profiles set user_id = %L where id = %L', upper(n1), u2), 'profiles_user_id_key');
  perform tests.affects(a, '他人のuser_idは書き換えられない(RLSで0件)',
    format('update public.profiles set user_id = ''hijacked'' where id = %L', u1), 0);

  perform tests.affects(a, 'user_id未設定の本人は20文字までのuser_idを新規設定できる',
    format('update public.profiles set user_id = %L where id = %L', n2, u2), 1);
  perform tests.as_owner();
  select user_id into s from public.profiles where id = u2;
  perform tests.eq(a, '設定したuser_idが実際に保存されている', s, n2);

  perform tests.as_user(u2);
  perform tests.denied(a, '一度設定したuser_idは本人でも変更できない',
    format('update public.profiles set user_id = ''renamed_id'' where id = %L', u2), 'user_id は変更できません');
  perform tests.denied(a, '設定済みのuser_idをnullに戻せない',
    format('update public.profiles set user_id = null where id = %L', u2), 'user_id は変更できません');
  perform tests.denied(a, '大文字小文字だけ変えたuser_idへの変更もできない',
    format('update public.profiles set user_id = %L where id = %L', upper(n2), u2), 'user_id は変更できません');
  perform tests.allowed(a, 'user_idを変えない更新(表示名だけの変更)は今まで通り通る',
    format('update public.profiles set display_name = ''表示名だけ変更'' where id = %L', u2));

  ------------------------------------------------ 匿名からの列単位の読み取り
  perform tests.as_anon();
  perform tests.allowed(a, '匿名は公開列(display_name)を読める',
    format('select display_name from public.profiles where id = %L', u1));
  perform tests.allowed(a, '匿名は公開列(id,user_id,bio,link,avatar_url,header_url,x_account,created_at)を読める',
    format('select id, handle, user_id, bio, link, avatar_url, header_url, x_account, created_at from public.profiles where id = %L', u1));
  perform tests.denied(a, '匿名は管理者フラグ(is_admin)を読めない',
    format('select is_admin from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名はパスワード有無(has_password)を読めない',
    format('select has_password from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名は停止状態(banned_at)を読めない',
    format('select banned_at from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名は停止理由(banned_reason)を読めない',
    format('select banned_reason from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名は規約同意時刻(terms_agreed_at)を読めない',
    format('select terms_agreed_at from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名は通知設定(notify_comments)を読めない',
    format('select notify_comments from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名はselect *で全列をまとめて取れない',
    format('select * from public.profiles where id = %L', u1), 'permission denied');
  perform tests.denied(a, '匿名は管理者の一覧(is_admin=true)を絞り込めない',
    'select id from public.profiles where is_admin = true', 'permission denied');

  perform tests.as_user(u2);
  perform tests.allowed(a, 'ログイン利用者は自分のプロフィールを全列取得できる',
    format('select * from public.profiles where id = %L', u2));
  perform tests.allowed(a, 'ログイン利用者は他人の公開プロフィールを読める',
    format('select display_name, user_id, bio from public.profiles where id = %L', u1));

  ------------------------------------------------ 停止状態(banned_at)の自己解除
  perform tests.as_user(adm);
  perform tests.allowed(a, '管理者は一般利用者を停止できる',
    format('select public.set_user_ban(%L, true, ''テスト用の停止'')', u2));
  perform tests.as_owner();
  select banned_at into t from public.profiles where id = u2;
  perform tests.ok(a, '停止した利用者のbanned_atが記録される', t is not null, 'banned_atが入っていません');

  perform tests.as_user(u2);
  select public.is_banned() into b;
  perform tests.as_owner();
  perform tests.eq(a, '停止中の本人はis_banned()がtrueになる', b, true);

  perform tests.as_user(u2);
  begin
    execute format('update public.profiles set banned_at = null where id = %L', u2);
  exception when others then null;
  end;
  perform tests.as_owner();
  select banned_at into t from public.profiles where id = u2;
  perform tests.ok(a, '停止中の本人が自分のbanned_atを消して停止を自己解除できない',
    t is not null, '本人がbanned_atをnullにでき、BANを自力で解除できてしまいます');

  update public.profiles set banned_at = now(), banned_reason = 'テスト用の停止' where id = u2;
  perform tests.as_user(u2);
  begin
    execute format('update public.profiles set banned_reason = ''書き換え'' where id = %L', u2);
  exception when others then null;
  end;
  perform tests.as_owner();
  select banned_reason into s from public.profiles where id = u2;
  perform tests.eq(a, '停止中の本人が停止理由(banned_reason)を書き換えられない', s, 'テスト用の停止');

  perform tests.as_user(u1);
  perform tests.affects(a, '一般利用者は他人のbanned_atを付けられない(RLSで0件)',
    format('update public.profiles set banned_at = now() where id = %L', u2), 0);

  perform tests.as_owner();
  update public.profiles set banned_at = now(), banned_reason = 'テスト用の停止' where id = u2;
  perform tests.as_user(adm);
  perform tests.allowed(a, '管理者は停止を解除できる',
    format('select public.set_user_ban(%L, false, null::text)', u2));
  perform tests.as_owner();
  select banned_at into t from public.profiles where id = u2;
  perform tests.ok(a, '停止解除するとbanned_atがnullに戻る', t is null, 'banned_atが残っています');

  ------------------------------------------------ 認証方式フラグ(has_password)
  perform tests.as_owner();
  update public.profiles set has_password = false where id = u1;
  perform tests.as_user(u1);
  begin
    execute format('update public.profiles set has_password = true where id = %L', u1);
  exception when others then null;
  end;
  perform tests.as_owner();
  select has_password into b from public.profiles where id = u1;
  perform tests.ok(a, '本人が認証方式フラグ(has_password)を勝手にtrueにできない',
    coalesce(b, false) = false, '本人がhas_passwordを自己申告で書き換えられます(サーバー実体と食い違う恐れ)');

  ------------------------------------------------------------------ 後片付け
  begin
    perform tests.as_owner();
    perform tests.cleanup_users(array[u1, u2, u3, adm, adm2]);
  exception when others then null;
  end;

  -- 後片付けの検証: テスト用に作った利用者がdevに残り続けていないか
  perform tests.as_owner();
  select count(*) into c1 from auth.users where email like 'test\_%@example.test';
  perform tests.ok(a, '後片付け(cleanup_users)でテスト用の利用者がDBに残らない',
    c1 = c0, 'テスト用の利用者が残っています(実行前=' || c0 || ' / 実行後=' || c1 || ')');
end $$;
