-- RLS:コメント のテスト（自動生成・dev専用）
do $$
declare
  a text := 'RLS:コメント';
  r_owner uuid; u1 uuid; u2 uuid; u3 uuid; u4 uuid; u5 uuid; adm uuid; ban uuid;
  pub_r uuid; pub_r2 uuid; priv_r uuid; closed_r uuid;
  c_top bigint; c_u2 bigint; c_rep bigint; c_other bigint; c_priv bigint;
  c_u5 bigint;
  n int; n_before int; ts timestamptz; ed timestamptz;
begin
  -- ================= 準備（すべて特権のまま作る＝連投制限や上限に掛からない） =================
  perform tests.as_owner();
  r_owner := tests.make_user();
  u1  := tests.make_user();
  u2  := tests.make_user();
  u3  := tests.make_user();
  u4  := tests.make_user();
  u5  := tests.make_user();
  adm := tests.make_user(true);
  ban := tests.make_user();
  update public.profiles set banned_at = now(), banned_reason = 'テスト用の停止' where id = ban;

  pub_r    := gen_random_uuid();
  pub_r2   := gen_random_uuid();
  priv_r   := gen_random_uuid();
  closed_r := gen_random_uuid();
  insert into public.recipes(id, owner_id, title, is_public, comments_disabled, created_at) values (pub_r,    r_owner, 'テスト公開投稿',        true,  false),
    (pub_r2,   r_owner, 'テスト公開投稿2',       true,  false),
    (priv_r,   r_owner, 'テスト非公開投稿',      false, false),
    (closed_r, r_owner, 'コメント停止中の投稿',  true,  true, now() - interval '1 hour');

  -- 既存コメント（created_at を過去にして30秒連投制限に掛からないようにする）
  insert into public.comments(recipe_id, user_id, body, created_at)
    values (pub_r, u1, 'u1の既存トップレベルコメント', now() - interval '3 hours') returning id into c_top;
  insert into public.comments(recipe_id, user_id, body, created_at)
    values (pub_r, u2, 'u2の既存コメント', now() - interval '2 hours') returning id into c_u2;
  insert into public.comments(recipe_id, user_id, body, created_at, parent_id)
    values (pub_r, u2, 'u2の既存返信', now() - interval '100 minutes', c_top) returning id into c_rep;
  insert into public.comments(recipe_id, user_id, body, created_at)
    values (pub_r2, u3, '別投稿の既存コメント', now() - interval '2 hours') returning id into c_other;
  insert into public.comments(recipe_id, user_id, body, created_at)
    values (priv_r, u2, '非公開投稿への既存コメント', now() - interval '90 minutes') returning id into c_priv;

  insert into public.comment_likes(comment_id, user_id) values (c_priv, u3);

  -- ================= 1) 読み取り（SELECT） =================
  perform tests.as_anon();
  select count(*)::int into n from public.comments where recipe_id = pub_r;
  perform tests.ok(a, '匿名でも公開投稿のコメントを読める', n >= 3, '見えた件数=' || n);

  select count(*)::int into n from public.comments where recipe_id = priv_r;
  perform tests.eq(a, '匿名は非公開投稿のコメントを読めない', n, 0);

  perform tests.as_user(u4);
  select count(*)::int into n from public.comments where recipe_id = priv_r;
  perform tests.eq(a, '第三者は非公開投稿のコメントを読めない', n, 0);

  perform tests.as_user(u2);
  select count(*)::int into n from public.comments where id = c_priv;
  perform tests.eq(a, 'コメントを書いた本人でも非公開投稿のコメントは読めない', n, 0);

  perform tests.as_user(adm);
  select count(*)::int into n from public.comments where id = c_priv;
  perform tests.eq(a, '管理者でも非公開投稿のコメントは読めない(読みポリシーに管理者例外は無い)', n, 0);

  perform tests.as_user(r_owner);
  select count(*)::int into n from public.comments where recipe_id = priv_r;
  perform tests.eq(a, '投稿者は自分の非公開投稿に付いたコメントを読める', n, 1);

  -- ================= 2) 投稿（INSERT） =================
  perform tests.as_user(u4);
  perform tests.denied(a, '他人名義(user_id偽装)ではコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u2, 'なりすましのコメント'), 'row-level security');

  perform tests.denied(a, '非公開投稿にはコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           priv_r, u4, '非公開投稿へのコメント'), 'row-level security');

  perform tests.denied(a, 'コメント停止中の投稿にはコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           closed_r, u4, '停止中の投稿へのコメント'), 'row-level security');

  perform tests.denied(a, '存在しない投稿にはコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           gen_random_uuid(), u4, '幽霊投稿へのコメント'), 'row-level security');

  perform tests.denied(a, 'NGワードを含むコメントは投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u4, 'お前なんか死ねばいい'), '使用できない語句');

  perform tests.denied(a, '本文が500文字を超えるコメントは保存できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u4, repeat('あ', 501)), 'comments_body_check');

  perform tests.denied(a, '本文が空のコメントは保存できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u4, ''), 'comments_body_check');

  perform tests.denied(a, '別の投稿のコメントを返信先(parent_id)にできない',
    format('insert into public.comments(recipe_id,user_id,body,parent_id) values (%L,%L,%L,%s)',
           pub_r, u4, '別投稿への返信', c_other), '不正な返信先');

  perform tests.denied(a, '返信に対する返信(2階層目)はできない',
    format('insert into public.comments(recipe_id,user_id,body,parent_id) values (%L,%L,%L,%s)',
           pub_r, u4, '返信への返信', c_rep), '不正な返信先');

  perform tests.denied(a, '存在しないコメントIDを返信先にできない',
    format('insert into public.comments(recipe_id,user_id,body,parent_id) values (%L,%L,%L,%s)',
           pub_r, u4, '幽霊への返信', 9223372036854775807), '不正な返信先');

  perform tests.as_anon();
  perform tests.denied(a, '未ログイン(匿名)ではコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u2, '匿名からのコメント'), 'row-level security');

  perform tests.as_user(ban);
  perform tests.denied(a, '利用停止(BAN)中の利用者はコメントを投稿できない',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, ban, '停止中の利用者のコメント'), 'ご利用を停止');

  perform tests.as_user(u1);
  perform tests.allowed(a, 'ログイン利用者は公開投稿にコメントを投稿できる',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u1, 'u1の新規コメント'));
  perform tests.denied(a, '同じ利用者の30秒以内の連投は拒否される',
    format('insert into public.comments(recipe_id,user_id,body) values (%L,%L,%L)',
           pub_r, u1, 'u1の連投コメント'), '30秒');

  perform tests.as_user(u3);
  perform tests.allowed(a, '同じ投稿のトップレベルコメントには返信できる',
    format('insert into public.comments(recipe_id,user_id,body,parent_id) values (%L,%L,%L,%s)',
           pub_r, u3, 'u3の返信', c_top));

  perform tests.as_user(u5);
  perform tests.allowed(a, 'created_atを過去に偽装した投稿自体は受理される(値は上書きされる)',
    format('insert into public.comments(recipe_id,user_id,body,created_at) values (%L,%L,%L,%L)',
           pub_r, u5, 'u5の日時偽装コメント', '2000-01-01 00:00:00+00'));

  perform tests.as_owner();
  select id, created_at into c_u5, ts from public.comments where user_id = u5 order by id desc limit 1;
  perform tests.ok(a, '投稿時のcreated_atはサーバー時刻で上書きされる(偽装できない)',
    ts is not null and ts > now() - interval '5 minutes', '保存されたcreated_at=' || coalesce(ts::text, 'null'));

  -- ================= 3) 編集（UPDATE） =================
  perform tests.as_user(u2);
  perform tests.affects(a, '他人のコメントは編集できない(0件しか効かない)',
    format('update public.comments set body = %L where id = %s', '他人による書き換え', c_top), 0);

  perform tests.as_anon();
  perform tests.affects(a, '匿名はコメントを編集できない(0件しか効かない)',
    format('update public.comments set body = %L where id = %s', '匿名による書き換え', c_top), 0);

  perform tests.as_user(adm);
  perform tests.affects(a, '管理者でも他人のコメント本文は編集できない(削除のみ可)',
    format('update public.comments set body = %L where id = %s', '管理者による書き換え', c_top), 0);

  perform tests.as_user(u1);
  perform tests.affects(a, '自分のコメントは編集できる',
    format('update public.comments set body = %L where id = %s', 'u1が編集した本文', c_top), 1);

  perform tests.as_owner();
  select edited_at into ed from public.comments where id = c_top;
  perform tests.ok(a, '編集するとedited_atが自動で入る', ed is not null,
    'edited_at=' || coalesce(ed::text, 'null'));
  select count(*)::int into n from public.comments where id = c_top and body = 'u1が編集した本文';
  perform tests.eq(a, '編集した本文が実際に保存されている', n, 1);

  perform tests.as_user(u1);
  perform tests.denied(a, '編集でrecipe_id(所属する投稿)を変更できない',
    format('update public.comments set recipe_id = %L where id = %s', pub_r2, c_top),
    '所属情報は変更できません');
  perform tests.denied(a, '編集でuser_id(投稿者)を変更できない',
    format('update public.comments set user_id = %L where id = %s', u2, c_top),
    '所属情報は変更できません');
  perform tests.denied(a, '編集でcreated_at(投稿日時)を変更できない',
    format('update public.comments set created_at = %L where id = %s', '2000-01-01 00:00:00+00', c_top),
    '所属情報は変更できません');
  perform tests.denied(a, '編集でNGワードを含む本文に書き換えられない',
    format('update public.comments set body = %L where id = %s', 'お前を殺す', c_top),
    '使用できない語句');

  perform tests.as_user(u2);
  perform tests.denied(a, '編集で返信先(parent_id)を付け替えられない',
    format('update public.comments set parent_id = null where id = %s', c_rep),
    '所属情報は変更できません');

  -- ================= 4) 削除（DELETE） =================
  perform tests.as_user(u2);
  perform tests.affects(a, '他人のコメントは削除できない(0件しか効かない)',
    format('delete from public.comments where id = %s', c_top), 0);

  perform tests.as_anon();
  perform tests.affects(a, '匿名はコメントを削除できない(0件しか効かない)',
    format('delete from public.comments where id = %s', c_top), 0);

  perform tests.as_user(r_owner);
  perform tests.affects(a, '投稿の所有者でも他人のコメントは削除できない',
    format('delete from public.comments where id = %s', c_top), 0);

  perform tests.as_user(u5);
  perform tests.affects(a, '自分のコメントは削除できる',
    format('delete from public.comments where id = %s', c_u5), 1);

  perform tests.as_user(adm);
  perform tests.affects(a, '管理者は他人のコメントを削除できる',
    format('delete from public.comments where id = %s', c_u2), 1);

  -- ================= 5) コメントへのいいね（comment_likes） =================
  perform tests.as_user(u2);
  perform tests.allowed(a, '公開投稿のコメントにいいねできる',
    format('insert into public.comment_likes(comment_id,user_id) values (%s,%L)', c_top, u2));

  perform tests.denied(a, '同じコメントに二重でいいねできない',
    format('insert into public.comment_likes(comment_id,user_id) values (%s,%L)', c_top, u2),
    'duplicate key');

  perform tests.denied(a, '他人名義のいいねはできない',
    format('insert into public.comment_likes(comment_id,user_id) values (%s,%L)', c_top, u4),
    'row-level security');

  perform tests.as_anon();
  perform tests.denied(a, '匿名はいいねできない',
    format('insert into public.comment_likes(comment_id,user_id) values (%s,%L)', c_top, u2),
    'row-level security');

  select count(*)::int into n from public.comment_likes where comment_id = c_top;
  perform tests.eq(a, '公開投稿のコメントのいいねは匿名でも読める', n, 1);

  select count(*)::int into n from public.comment_likes where comment_id = c_priv;
  perform tests.eq(a, '匿名は非公開投稿のコメントのいいねを読めない', n, 0);

  perform tests.as_user(u4);
  select count(*)::int into n from public.comment_likes where comment_id = c_priv;
  perform tests.eq(a, '第三者は非公開投稿のコメントのいいねを読めない', n, 0);

  perform tests.as_user(r_owner);
  select count(*)::int into n from public.comment_likes where comment_id = c_priv;
  perform tests.eq(a, '投稿者は自分の非公開投稿のコメントのいいねを読める', n, 1);

  perform tests.as_user(u4);
  perform tests.denied(a, '見えないはずの非公開投稿のコメントにいいねできない',
    format('insert into public.comment_likes(comment_id,user_id) values (%s,%L)', c_priv, u4),
    'row-level security');

  perform tests.affects(a, '他人のいいねは取り消せない(0件しか効かない)',
    format('delete from public.comment_likes where comment_id = %s and user_id = %L', c_top, u2), 0);

  perform tests.as_anon();
  perform tests.affects(a, '匿名は他人のいいねを取り消せない(0件しか効かない)',
    format('delete from public.comment_likes where comment_id = %s and user_id = %L', c_top, u2), 0);

  perform tests.as_user(u2);
  perform tests.affects(a, '自分のいいねは取り消せる',
    format('delete from public.comment_likes where comment_id = %s and user_id = %L', c_top, u2), 1);

  -- ================= 6) 連鎖削除（返信の後始末） =================
  perform tests.as_owner();
  select count(*)::int into n_before from public.comments where parent_id = c_top;
  perform tests.ok(a, '削除前提の確認: トップレベルコメントに返信が付いている', n_before >= 1,
    '返信の件数=' || n_before);
  delete from public.comments where id = c_top;
  select count(*)::int into n from public.comments where parent_id = c_top;
  perform tests.eq(a, 'トップレベルコメントを削除すると返信も一緒に消える', n, 0);

  -- ================= 後片付け（失敗しても止めない） =================
  begin
    perform tests.as_owner();
    delete from public.recipes where owner_id = r_owner;
    perform tests.cleanup_users(array[r_owner, u1, u2, u3, u4, u5, adm, ban]);
  exception when others then null;
  end;
end $$;
